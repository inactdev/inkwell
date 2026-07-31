import Foundation
import Network

/// Hands captures over to the backend when it's reachable, quietly, and
/// retries when it isn't. Never blocks or is consulted by capture itself -
/// see docs/api-contract.md for the full offline/retry contract this
/// implements.
@MainActor
@Observable
final class SyncCoordinator {
    private let store: InklingStore
    private let baseURL: URL
    private let session: URLSession
    private let pathMonitor = NWPathMonitor()
    private var timer: Timer?
    private var wasReachable = false
    private(set) var isSyncing = false

    init(store: InklingStore, baseURL: URL = AppConfig.backendBaseURL, session: URLSession = .shared) {
        self.store = store
        self.baseURL = baseURL
        self.session = session
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncAll() }
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if reachable && !self.wasReachable {
                    await self.syncAll()
                }
                self.wasReachable = reachable
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "inkwell.sync.pathmonitor"))

        Task { await syncAll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        pathMonitor.cancel()
    }

    /// Pushes every unsynced inkling once. Safe to call repeatedly - each
    /// inkling that succeeds clears its own "not yet synced" indicator;
    /// anything that fails is simply left for the next pass.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        for inkling in store.inklings where !inkling.isSynced {
            await syncOne(inkling)
        }
    }

    private func syncOne(_ inkling: Inkling) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("inklings"))
        request.httpMethod = "POST"

        var form = MultipartFormData()
        let iso = ISO8601DateFormatter()
        form.addField("id", inkling.id.uuidString)
        form.addField("created", iso.string(from: inkling.createdAt))
        form.addField("updated", iso.string(from: inkling.updatedAt))
        form.addField("text", inkling.text)

        if let audioFileName = inkling.audioFileName {
            let audioURL = store.directory.appendingPathComponent(audioFileName)
            if let audioData = try? Data(contentsOf: audioURL) {
                form.addFile("audio", filename: audioFileName, contentType: "audio/m4a", data: audioData)
            }
        }

        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return
            }
            guard
                let decoded = try? JSONDecoder().decode(SyncResponse.self, from: data),
                let syncedDate = iso.date(from: decoded.syncedAt)
            else {
                return
            }
            var updated = inkling
            updated.syncedAt = syncedDate
            store.save(updated)
        } catch {
            // Offline or the backend is down - quiet, retried next pass.
        }
    }

    private struct SyncResponse: Decodable {
        let id: String
        let syncedAt: String
    }
}
