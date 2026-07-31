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

    func requestAuthorization() async -> Bool { true }

    func startCapturing(to fileURL: URL) throws {
        transcript = ""
        isCapturing = true
    }

    func stopCapturing() {
        isCapturing = false
    }

    func setInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {
        onInterruption = handler
    }

    /// What the real engine's interruption observer does: stop for real,
    /// then tell the owner the segment is over.
    func interrupt() {
        stopCapturing()
        onInterruption?()
    }
}
