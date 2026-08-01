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
    var saveFailed = false
    /// Presents the failure alert. SwiftUI resets this to false the moment
    /// the owner dismisses the alert, so it cannot double as the record of
    /// the failure itself - that is `recognitionFailed`'s job.
    var showRecognitionFailureAlert = false
    /// The durable fact that this draft's latest capture segment failed,
    /// outliving the alert's dismissal. While true, the audio preserved on
    /// disk may be the only record of the utterance, so an empty Done must
    /// not silently discard it. Cleared when a new segment starts or the
    /// draft ends.
    private(set) var recognitionFailed = false
    /// Decided here, not in the view: whether any words had made it into the
    /// draft by the time recognition failed, so the alert can reassure
    /// ("your words are here") instead of implying they were lost.
    private(set) var recognitionFailedWithWordsHeard = false

    private let engine: any CaptureEngine
    private let store: InklingStore
    /// Set synchronously so a second tap can't start a second capture while
    /// the first is still awaiting authorization.
    private var isStartingListening = false
    /// True only while a dictation segment is actively contributing live
    /// words. `engine.transcript` can be written asynchronously even after
    /// `stopCapturing()` - the recognizer's settled final result still
    /// arrives on its own queue - so it is never safe to read as "live" on
    /// its own. Without this scope, a segment's words stay readable as live
    /// after they were already folded into `committedText`: the idle screen
    /// after Done keeps showing a stray Done button that saves a duplicate
    /// inkling, and a save-failure retry re-appends the same words on top
    /// of themselves.
    private var isSegmentLive = false

    var liveTranscript: String { isSegmentLive ? engine.transcript : "" }
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

    init(store: InklingStore, engine: any CaptureEngine = AudioCaptureEngine()) {
        self.store = store
        self.engine = engine
        engine.setInterruptionHandler { [weak self] in
            Task { @MainActor in self?.captureWasInterrupted() }
        }
        engine.setRecognitionFailureHandler { [weak self] in
            Task { @MainActor in self?.captureRecognitionFailed() }
        }
    }

    /// The system took the audio session mid-segment (a call, Siri, an
    /// alarm). Nothing further will arrive, so fold what was heard into the
    /// draft and hand it to the keyboard rather than leaving the well
    /// rippling at a microphone that is no longer ours. Delegates to
    /// beginEditing() rather than duplicating its commit-then-stop-then-mode
    /// sequence, so this never has to assume the engine already tore itself
    /// down before calling in - stopCapturing() is idempotent, so calling it
    /// again here is harmless.
    private func captureWasInterrupted() {
        guard mode == .listening else { return }
        beginEditing()
        // Nothing was actually heard - an interruption a moment after
        // tapping the well shouldn't strand the owner in an empty editor
        // with the keyboard up over words that were never said.
        if !hasContent {
            discardDraft()
        }
    }

    /// The recognizer settled with an error, or stopped making transcript
    /// progress - whether it never produced a word or went dead after some;
    /// see `AudioCaptureEngine.silenceTimeout`. Unlike an interruption,
    /// nothing about this is self-evident to the owner, so it must say so
    /// rather than just quietly dropping back to idle. Always lands in
    /// editing, even with nothing heard: `engine.stopCapturing()` already ran,
    /// but the draft (and any audio already written to disk for it) stays
    /// alive until the owner decides what to do with it - typing over a
    /// failed recognition is the one path already proven to work, and a
    /// silent reset here would just be this same bug moved later.
    private func captureRecognitionFailed() {
        guard mode == .listening else { return }
        beginEditing()
        recognitionFailedWithWordsHeard = !committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        recognitionFailed = true
        showRecognitionFailureAlert = true
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
        guard mode != .listening, !isStartingListening else { return }
        isStartingListening = true
        Task { @MainActor in
            defer { isStartingListening = false }
            let authorized = await engine.requestAuthorization()
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
                // multi-segment capture becomes common. Known limitation,
                // accepted for now: the silence watchdog re-arms on every
                // transcript change, so it can also end a segment after an
                // ordinary mid-dictation pause - resuming from that alert
                // truncates the earlier segment's recording just like a
                // manual edit-then-resume does (the words themselves survive
                // in committedText). Full multi-segment audio preservation
                // is queued as separate work (the offline-first capture
                // rebuild), not part of this fix.
                try engine.startCapturing(to: store.audioURL(for: draftID))
                mode = .listening
                isSegmentLive = true
                recognitionFailed = false
            } catch {
                authorizationDenied = true
            }
        }
    }

    private func commitLiveTranscript() {
        guard isSegmentLive else { return }
        if !liveTranscript.isEmpty {
            committedText = displayedText
        }
        isSegmentLive = false
    }

    /// Saves instantly to disk, no network involved, then resets for the next capture.
    func done() {
        commitLiveTranscript()
        engine.stopCapturing()

        let text = committedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // After a recognition failure, the recording preserved on disk
            // may be the only record of what was said. Done with nothing
            // typed must not silently take it - only the explicit Discard
            // action may delete it. Absent such a failure, an empty Done is
            // the owner walking away from a draft they chose to leave blank.
            if recognitionFailed {
                mode = .editing
                return
            }
            discardDraft()
            return
        }

        let now = Date()
        let audioURL = store.audioURL(for: draftID)
        // `draftID` is fresh per capture, so a file at this URL can only be
        // this draft's own recording - including when dictation was stopped
        // earlier to edit the words by hand.
        let hasAudio = FileManager.default.fileExists(atPath: audioURL.path)
        let inkling = Inkling(
            id: draftID,
            text: text,
            createdAt: now,
            updatedAt: now,
            audioFileName: hasAudio ? audioURL.lastPathComponent : nil,
            syncedAt: nil
        )
        do {
            try store.save(inkling)
        } catch {
            // Keep the words on screen: nothing was persisted, so resetting
            // here would lose the capture for real. Dictation is already
            // stopped by this point, so drop to editing rather than leaving
            // the screen claiming to listen to an engine that isn't running -
            // that state can't be left by any control except the well, and
            // it makes the retry the alert asks for directly typeable.
            mode = .editing
            saveFailed = true
            return
        }

        showConfirmation = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            showConfirmation = false
        }
        reset()
    }

    func discard() {
        engine.stopCapturing()
        discardDraft()
    }

    /// Resets after a draft nothing will ever reference again, taking its
    /// recording with it - otherwise every discarded capture would leave an
    /// orphaned .m4a behind forever.
    private func discardDraft() {
        try? FileManager.default.removeItem(at: store.audioURL(for: draftID))
        reset()
    }

    private func reset() {
        mode = .idle
        committedText = ""
        draftID = UUID()
        isSegmentLive = false
        recognitionFailed = false
        recognitionFailedWithWordsHeard = false
    }
}
