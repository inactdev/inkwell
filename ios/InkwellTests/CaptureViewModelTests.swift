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
/// produces a real transcript, so this drives the real `startListening` /
/// `beginEditing` / `done` path against the real `AudioCaptureEngine` (mic
/// permissions are pre-granted in this environment, same as
/// AudioSpikeTests) and injects the delayed post-stop delivery directly,
/// since that race can't be reproduced deterministically with real speech.
@MainActor
final class CaptureViewModelTests: XCTestCase {

    func testCommittedTextIsNotReReadAsLiveAfterCommit() async throws {
        let granted = await AudioCaptureEngine.requestAuthorization()
        try XCTSkipUnless(granted, "Microphone/speech authorization not granted in this environment")

        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureViewModelTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: storeDirectory) }
        let store = InklingStore(directory: storeDirectory)
        let engine = AudioCaptureEngine()
        let viewModel = CaptureViewModel(store: store, engine: engine)

        // Start a real dictation segment against the real (silent) hardware
        // input, exactly as tapping the well does.
        viewModel.tapInkwell()
        try await waitUntil(timeout: 5) { viewModel.isListening }

        // Simulate the recognizer having streamed some live words.
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
        // relies on) - the guarantee has to live here instead.
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
        let saved = store.inklings
        XCTAssertEqual(saved.count, 1, "Done must persist exactly one inkling, not a duplicate")
        XCTAssertEqual(saved.first?.text, "Rig a solar charger for the buoy")

        // A second Done tap - the stray-button scenario the review flagged -
        // must be a no-op: nothing left to commit, nothing new to save.
        viewModel.done()
        XCTAssertEqual(store.inklings.count, 1, "tapping Done again with nothing live must not save a duplicate")
    }

    private func waitUntil(timeout: TimeInterval, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
