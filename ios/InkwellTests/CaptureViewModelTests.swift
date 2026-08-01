import XCTest
@testable import Inkwell

/// Regression coverage for a review finding: `liveTranscript` used to read
/// straight through to `AudioCaptureEngine.transcript`, which can still be
/// written asynchronously after `stopCapturing()` (the recognizer's settled
/// final result arrives on its own queue, independent of when the segment
/// was folded into `committedText`). That let a segment's words be read
/// back in as "live" after they had already been committed - producing a
/// stray Done button on the idle screen after a successful save (which then
/// saved a second, duplicate inkling), and doubled text on a save-failure
/// retry. XCUITests never caught this because the headless simulator never
/// produces a real transcript.
///
/// The invariant lives entirely in `CaptureViewModel`, so these drive the
/// real `startListening` / `beginEditing` / `done` paths through the
/// `CaptureEngine` seam. Nothing here touches a microphone, a speech
/// authorization grant, or an audio session: the races below - a delayed
/// post-stop delivery, a failed save, a session interruption - can't be
/// reproduced deterministically against real hardware, and a test that
/// silently skipped wherever the TCC grant is missing would let this
/// regression back in with a green suite.
@MainActor
final class CaptureViewModelTests: XCTestCase {

    func testCommittedTextIsNotReReadAsLiveAfterCommit() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        // Start a dictation segment, exactly as tapping the well does.
        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }

        // The recognizer streams some live words.
        engine.transcript = "Rig a solar charger for the buoy"
        XCTAssertEqual(viewModel.displayedText, "Rig a solar charger for the buoy")

        // Tap the words to edit - folds the live segment into committedText
        // and stops the engine, exactly like beginEditing().
        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { !viewModel.isListening }
        XCTAssertEqual(viewModel.committedText, "Rig a solar charger for the buoy")

        // The race: the recognizer's settled final result is delivered on
        // its own queue and can still land after stopCapturing() returned.
        // Nothing in AudioCaptureEngine prevents this by design (stopping a
        // segment must not silently drop a final delivery the audio spike
        // relies on) - the guarantee has to live in the view model instead.
        engine.transcript = "Rig a solar charger for the buoy"

        XCTAssertEqual(
            viewModel.liveTranscript, "",
            "a committed segment's words must never be readable as live again, even if the engine still holds them"
        )
        XCTAssertEqual(
            viewModel.displayedText, "Rig a solar charger for the buoy",
            "displayedText must not double up the already-committed words with the stale live transcript"
        )

        viewModel.done()

        XCTAssertFalse(viewModel.hasContent, "the idle screen after Done must not show a stray Done button")
        XCTAssertEqual(store.inklings.count, 1, "Done must persist exactly one inkling, not a duplicate")
        XCTAssertEqual(store.inklings.first?.text, "Rig a solar charger for the buoy")

        // A second Done tap - the stray-button scenario the review flagged -
        // must be a no-op: nothing left to commit, nothing new to save.
        viewModel.done()
        XCTAssertEqual(store.inklings.count, 1, "tapping Done again with nothing live must not save a duplicate")
    }

    /// Done is reachable from the footer while still listening. When the save
    /// then fails, the engine has already been stopped, so leaving `mode` at
    /// `.listening` left the well rippling at nothing - and `startListening`
    /// refuses to restart from `.listening`, so the only way out was tapping
    /// the well.
    func testFailedSaveLeavesTheWordsEditableRatherThanStillListening() async throws {
        let store = try makeUnwritableStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }
        engine.transcript = "Check the mooring line after the storm"

        viewModel.done()

        XCTAssertTrue(viewModel.saveFailed, "a save that never reached disk must surface as a failure")
        XCTAssertFalse(
            viewModel.isListening,
            "nothing is being captured after a failed save - the screen must not claim otherwise"
        )
        XCTAssertEqual(
            viewModel.committedText, "Check the mooring line after the storm",
            "the words are all that survived the failed save - they must still be there to retry with"
        )
        XCTAssertEqual(store.inklings.count, 0)

        // The retry the alert asks for: it fails again here, but it must not
        // append the same words to themselves on the way through.
        viewModel.done()
        XCTAssertEqual(
            viewModel.committedText, "Check the mooring line after the storm",
            "retrying Done must not double the text it is retrying with"
        )
    }

    /// A call, Siri, or an alarm takes the audio session away mid-segment.
    /// The engine is stopped by then, so the screen must stop claiming to
    /// listen and must keep the words it already heard.
    func testInterruptionEndsTheSegmentAndKeepsTheWords() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }
        engine.transcript = "Swap the buoy battery before Friday"

        engine.interrupt()
        try await waitUntil(timeout: 2) { !viewModel.isListening }

        XCTAssertEqual(
            viewModel.committedText, "Swap the buoy battery before Friday",
            "words heard before the interruption must survive it"
        )
        XCTAssertEqual(viewModel.liveTranscript, "", "the interrupted segment is over - nothing about it is still live")

        // And the segment really ended: the well can start a fresh one.
        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }
    }

    /// The interruption contract: whoever reports the interruption owes no
    /// promise about having torn the segment down first. The real engine
    /// happens to stop itself before calling in, but the view model must not
    /// lean on that - it has to end the segment itself, or a notifier that
    /// doesn't (an app-lifecycle hook, a future route-change observer) leaves
    /// the mic live behind an editing screen.
    func testInterruptionStopsTheEngineEvenWhenItIsStillCapturing() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }
        engine.transcript = "Reroute the swim line around the mooring"
        XCTAssertTrue(engine.isCapturing, "the segment is running - otherwise this proves nothing")

        engine.interruptWithoutStopping()
        try await waitUntil(timeout: 2) { !viewModel.isListening }

        XCTAssertFalse(
            engine.isCapturing,
            "the view model must stop the engine itself rather than assume the interruption already did"
        )
        XCTAssertEqual(
            viewModel.committedText, "Reroute the swim line around the mooring",
            "words heard before the interruption must survive it"
        )
        XCTAssertEqual(viewModel.mode, .editing)
    }

    /// An interruption a moment after tapping the well, before any words
    /// were heard, must not strand the owner in an empty editor with the
    /// keyboard up - there is nothing there to edit.
    func testInterruptionBeforeAnyWordsReturnsToIdle() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }

        engine.interrupt()
        try await waitUntil(timeout: 2) { !viewModel.isListening }

        XCTAssertEqual(viewModel.mode, .idle, "an interruption with nothing captured must return to idle, not editing")
        XCTAssertFalse(viewModel.hasContent)
        XCTAssertEqual(store.inklings.count, 0, "nothing was said, so nothing should be saved")
    }

    /// The bug this task exists to fix: a recognizer that produces nothing
    /// (settles with an error, or the engine's silence timeout gives up)
    /// used to leave the screen claiming "Listening…" forever, with nothing
    /// to act on. It must now surface as a visible failure, and it must not
    /// destroy the draft - the audio already on disk for it is the only
    /// record of what was said if no words were ever recognized.
    func testRecognitionFailureWithNoWordsHeardSurfacesAndKeepsTheDraftEditable() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }

        engine.failRecognition()
        try await waitUntil(timeout: 2) { !viewModel.isListening }

        XCTAssertTrue(viewModel.recognitionFailed, "a recognizer that produced nothing must not fail silently")
        XCTAssertTrue(viewModel.showRecognitionFailureAlert, "the failure must present its alert, not just record itself")
        XCTAssertFalse(
            viewModel.recognitionFailedWithWordsHeard,
            "nothing was heard - the alert must not claim any words are here"
        )
        XCTAssertEqual(viewModel.mode, .editing, "the draft must stay open to type into, not reset to idle")
        XCTAssertEqual(store.inklings.count, 0, "nothing was heard, so nothing should have been saved yet")

        // The proven-working typed path recovers the idea.
        viewModel.updateCommittedText("Check the mooring line after the storm")
        viewModel.done()
        XCTAssertEqual(store.inklings.count, 1)
    }

    /// Some words came through before the recognizer died mid-segment - those
    /// words must survive exactly like an interruption's do.
    func testRecognitionFailureAfterPartialWordsKeepsThoseWords() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }
        engine.transcript = "Swap the buoy battery"

        engine.failRecognition()
        try await waitUntil(timeout: 2) { !viewModel.isListening }

        XCTAssertTrue(viewModel.recognitionFailed)
        XCTAssertTrue(viewModel.showRecognitionFailureAlert)
        XCTAssertTrue(
            viewModel.recognitionFailedWithWordsHeard,
            "words survived - the alert must reassure, not read as though they were lost"
        )
        XCTAssertEqual(viewModel.committedText, "Swap the buoy battery", "words heard before the failure must survive it")
        XCTAssertEqual(viewModel.mode, .editing)
    }

    /// The non-negotiable behind the whole fix: after a recognition failure
    /// with nothing heard, the recording preserved on disk may be the only
    /// record of the utterance, so Done with nothing typed must not silently
    /// take it. Only the explicit Discard action may. The gate is the
    /// failure itself, not the file's existence - the real engine creates
    /// the file at the start of every segment, so "a file exists" is true
    /// for every voice-started draft and would turn every empty Done into a
    /// no-op.
    func testEmptyDoneAfterRecognitionFailureKeepsThePreservedAudio() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }

        // The segment's audio file reached disk at segment start, exactly as
        // the real engine writes it, before recognition died.
        let audioURL = store.audioURL(for: viewModel.draftID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        engine.failRecognition()
        try await waitUntil(timeout: 2) { !viewModel.isListening }

        // The owner must dismiss the modal alert before Done is even
        // tappable - the durable failure fact has to outlive that dismissal,
        // or this protection would be dead code in the real app.
        viewModel.showRecognitionFailureAlert = false

        let draftID = viewModel.draftID
        viewModel.done()

        XCTAssertEqual(viewModel.mode, .editing, "Done with nothing typed must keep the draft open, not reset")
        XCTAssertEqual(viewModel.draftID, draftID, "the draft holding the recording must survive an empty Done")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: audioURL.path),
            "the recording is the only record of what was said - Done must never silently delete it"
        )
        XCTAssertEqual(store.inklings.count, 0)

        // Discarding stays the owner's own explicit choice - and still works.
        viewModel.discard()
        XCTAssertEqual(viewModel.mode, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    /// Without a recognition failure the recording is not the last record of
    /// anything: leaving the editor empty and tapping Done is the owner
    /// walking away, and it must still clear out to idle - taking the
    /// segment's audio file with it - even though the real engine created
    /// that file the moment the segment started.
    func testEmptyDoneWithoutARecognitionFailureStillResetsToIdle() async throws {
        let store = try makeStore()
        let engine = FakeCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { viewModel.isListening }
        let audioURL = store.audioURL(for: viewModel.draftID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        // Tap the well to edit, say nothing, type nothing, tap Done.
        viewModel.tapInkwell()
        try await waitUntil(timeout: 2) { !viewModel.isListening }
        viewModel.done()

        XCTAssertEqual(viewModel.mode, .idle, "an empty draft the owner walked away from must not stay open")
        XCTAssertFalse(viewModel.hasContent)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: audioURL.path),
            "the abandoned draft's audio must not be orphaned on disk"
        )
        XCTAssertEqual(store.inklings.count, 0)
    }

    private func makeStore() throws -> InklingStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureViewModelTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return InklingStore(directory: directory)
    }

    /// A store whose directory can never be created, because its parent is a
    /// regular file - the simplest way to make `save` genuinely throw.
    private func makeUnwritableStore() throws -> InklingStore {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureViewModelTests-blocked-\(UUID().uuidString)")
        try Data().write(to: blocker)
        addTeardownBlock { try? FileManager.default.removeItem(at: blocker) }
        return InklingStore(directory: blocker.appendingPathComponent("inklings", isDirectory: true))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Stands in for `AudioCaptureEngine` with the timing under the test's
/// control: the transcript can be written whenever the scenario needs it,
/// including after the segment was stopped, which is exactly the delivery
/// real speech recognition makes on its own queue.
private final class FakeCaptureEngine: CaptureEngine, @unchecked Sendable {
    var transcript: String = ""
    var inputLevel: Float = 0
    private(set) var isCapturing = false
    private var onInterruption: (@Sendable () -> Void)?
    private var onRecognitionFailure: (@Sendable () -> Void)?

    func requestAuthorization() async -> Bool { true }

    func startCapturing(to fileURL: URL) throws {
        // The real engine creates the audio file at segment start, before a
        // single frame arrives - the fake must leave the same footprint or
        // tests would exercise on-disk states production can never produce.
        FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        transcript = ""
        isCapturing = true
    }

    func stopCapturing() {
        isCapturing = false
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        onInterruption = handler
    }

    func setRecognitionFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        onRecognitionFailure = handler
    }

    /// What the real engine's interruption observer does: stop for real,
    /// then tell the owner the segment is over.
    func interrupt() {
        stopCapturing()
        onInterruption?()
    }

    /// The same notification from a source that has *not* stopped the engine
    /// first - nothing in the protocol promises it has.
    func interruptWithoutStopping() {
        onInterruption?()
    }

    /// What the real engine does on a recognizer error or a silence timeout:
    /// stop for real, then tell the owner nothing came through.
    func failRecognition() {
        stopCapturing()
        onRecognitionFailure?()
    }
}
