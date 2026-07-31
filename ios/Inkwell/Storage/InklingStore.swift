import Foundation

/// One JSON file per inkling on device, mirroring the backend's one-file-
/// per-inkling storage. Saves are synchronous, atomic file writes so a
/// capture is durable the instant `save` returns, no network or database
/// involved, and it survives the app being killed.
@Observable
final class InklingStore {
    private(set) var inklings: [Inkling] = []
    let directory: URL

    init(directory: URL = InklingStore.defaultDirectory()) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    static func defaultDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Inklings", isDirectory: true)
    }

    func audioURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).m4a")
    }

    private func jsonURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func reload() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            inklings = []
            return
        }
        let decoder = Self.makeDecoder()
        inklings = files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Inkling? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Inkling.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func save(_ inkling: Inkling) -> Inkling {
        let encoder = Self.makeEncoder()
        guard let data = try? encoder.encode(inkling) else { return inkling }
        try? data.write(to: jsonURL(for: inkling.id), options: .atomic)

        if let index = inklings.firstIndex(where: { $0.id == inkling.id }) {
            inklings[index] = inkling
        } else {
            inklings.append(inkling)
        }
        inklings.sort { $0.createdAt > $1.createdAt }
        return inkling
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
