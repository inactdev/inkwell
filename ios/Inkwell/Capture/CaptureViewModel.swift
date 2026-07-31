import Foundation

enum CaptureMode {
    case idle
    case listening
    case editing
}

@MainActor
@Observable
final class CaptureViewModel {
    private(set) var mode: CaptureMode = .idle
    private(set) var committedText: String = ""
    private(set) var draftID = UUID()
    var showConfirmation = false
    var authorizationDenied = false

    private let engine: AudioCaptureEngine
    private let store: InklingStore

    var liveTranscript: String { engine.transcript }
    var inputLevel: Float { engine.inputLevel }
    var isListening: Bool { mode == .listening }

    /// Committed text plus whatever the recognizer has produced so far this segment.
    var displayedText: String {
        if liveTranscript.isEmpty { return committedText }
        if committedText.isEmpty { return liveTranscript }
        return committedText + " " + liveTranscript
    }

    var hasContent: Bool {
        !committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !liveTranscript.isEmpty
    }

    init(store: InklingStore, engine: AudioCaptureEngine = AudioCaptureEngine()) {
        self.store = store
        self.engine = engine
    }

    /// Tapping the well: start listening from idle/editing, or - while
    /// already listening - freeze the transcript and hand over to the
    /// keyboard, matching "tapping the words gives you the keyboard to edit."
    func tapInkwell() {
        switch mode {
        case .idle, .editing:
            startListening()
        case .listening:
            beginEditing()
        }
    }

    func beginEditing() {
        commitLiveTranscript()
        engine.stopCapturing()
        mode = .editing
    }

    /// The mic key: resumes dictation after a manual edit.
    func resumeDictation() {
        startListening()
    }

    func updateCommittedText(_ text: String) {
        committedText = text
    }

    private func startListening() {
        guard mode != .listening else { return }
        Task { @MainActor in
            let authorized = await AudioCaptureEngine.requestAuthorization()
            guard authorized else {
                authorizationDenied = true
                return
            }
            do {
                // Re-opening the same URL starts a fresh recording for this
                // segment - resuming dictation after an edit overwrites the
                // previous segment's audio rather than appending to it. The
                // transcript carries the full history forward; only the
                // audio companion is scoped to the most recent segment. A
                // fine tradeoff for the skeleton; worth revisiting if
                // multi-segment capture becomes common.
                try engine.startCapturing(to: store.audioURL(for: draftID))
                mode = .listening
            } catch {
                authorizationDenied = true
            }
        }
    }

    private func commitLiveTranscript() {
        guard !liveTranscript.isEmpty else { return }
        committedText = displayedText
    }

    /// Saves instantly to disk, no network involved, then resets for the next capture.
    func done() {
        commitLiveTranscript()
        let wasRecording = engine.isRecording
        engine.stopCapturing()

        let text = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            reset()
            return
        }

        let now = Date()
        let audioURL = store.audioURL(for: draftID)
        let hasAudio = wasRecording && FileManager.default.fileExists(atPath: audioURL.path)
        let inkling = Inkling(
            id: draftID,
            text: text,
            createdAt: now,
            updatedAt: now,
            audioFileName: hasAudio ? audioURL.lastPathComponent : nil,
            syncedAt: nil
        )
        store.save(inkling)

        showConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            showConfirmation = false
        }
        reset()
    }

    func discard() {
        engine.stopCapturing()
        reset()
    }

    private func reset() {
        mode = .idle
        committedText = ""
        draftID = UUID()
    }
}
