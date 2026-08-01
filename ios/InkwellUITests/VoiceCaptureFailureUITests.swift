import XCTest

/// Regression coverage for issue #12: the captain tapped the well, the UI
/// looked right, but speaking produced no transcript and nothing ever
/// happened - a silently dropped idea. Reproduced against the real
/// production path (real hardware `inputNode`, real permissions, real UI):
/// this headless Simulator has no live mic input, so a capture segment here
/// always runs into exactly the silence `AudioCaptureEngine.silenceTimeout`
/// exists to catch. That makes this environment a standing regression test
/// for the fix, not just a one-off repro - unlike a human's real voice, it
/// can't accidentally produce words that would let this test pass for the
/// wrong reason.
@MainActor
final class VoiceCaptureFailureUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSilentRecognitionFailureSurfacesAndStaysRecoverable() throws {
        let app = XCUIApplication()
        app.launch()

        let inkwell = app.otherElements["inkwell"]
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))
        inkwell.tap()
        dismissSystemAlertIfPresent(app)
        dismissSystemAlertIfPresent(app) // speech recognition, then microphone

        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "never reached listening mode")
        attachScreenshot(app, name: "01-listening")

        // The one thing this environment's silence guarantees: no words will
        // ever arrive, so the failure alert is the only thing that can end this wait.
        let alert = app.alerts["Didn't catch that"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15), "a dead recognizer must surface, not hang silently")
        attachScreenshot(app, name: "02-failure-alert")
        alert.buttons["OK"].tap()

        // The draft must still be there to finish by typing - the one path
        // already proven to work - not reset to idle as if nothing happened.
        let editor = app.textViews["transcriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3), "the draft must stay open to type into")
        editor.tap()
        editor.typeText("Check the mooring line after the storm.")
        dismissKeyboardTipIfPresent(app)
        attachScreenshot(app, name: "03-recovered-by-typing")

        let doneButton = app.buttons["keyboardDone"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.tap()

        let toast = app.staticTexts["confirmationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "the recovered capture must save like any other")
        attachScreenshot(app, name: "04-saved")
    }
}
