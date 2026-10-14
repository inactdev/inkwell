import XCTest

/// Drives the real capture flow through the actual UI - not a unit test of
/// the view model - and attaches a screenshot at each stage so the outcome
/// can be judged visually. The simulator has no live speaker in this
/// environment, so dictation stays on its "Listening…" placeholder; typed
/// text stands in for what a human would have said, exercising the same
/// edit-and-save path either way.
///
/// The app is voice-first: capture begins the moment it launches, with no
/// tap required to start it (see
/// `testListeningStartsAutomaticallyOnLaunchWithoutTappingTheWell` below,
/// which pins that contract on its own). Every flow here drives that
/// same already-listening state rather than tapping the well first - tapping
/// an already-listening well stops it and hands over to the keyboard, so an
/// extra tap here would skip straight past "Listening…" into editing.
@MainActor
final class CaptureFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The bug this task exists to fix: the app opened straight to an idle
    /// well and never captured anything unless the owner happened to tap it
    /// first - indistinguishable, from the idle screen, from an app that was
    /// already listening. Pins the fix on its own, end to end through the
    /// real UI: launch, never tap the well, and still get all the way to a
    /// saved inkling from what was "said" right after opening.
    func testListeningStartsAutomaticallyOnLaunchWithoutTappingTheWell() throws {
        let app = XCUIApplication()
        app.launch()

        // Permission is requested automatically on launch now, not after a
        // first tap - these dialogs are pre-granted in CI, so normally
        // nothing appears here, but dismiss defensively in case a fresh
        // simulator ever reaches this test ungranted.
        dismissSystemAlertIfPresent(app)
        dismissSystemAlertIfPresent(app) // speech recognition, then microphone

        let inkwell = app.otherElements["inkwell"]
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))
        XCTAssertEqual(
            inkwell.label, "Stop and edit",
            "the well's own accessibility label must already read as listening on launch, not idle"
        )

        // No tap on `inkwell` anywhere above - its existence here is the proof.
        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "capture must begin without an initial tap")
        attachScreenshot(app, name: "00-auto-listening")

        transcript.tap()
        let editor = app.textViews["transcriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Patch the leak in the dinghy before the next swell.")
        dismissKeyboardTipIfPresent(app)

        let doneButton = app.buttons["keyboardDone"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.tap()

        let toast = app.staticTexts["confirmationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3), "what was heard right after launch must save like any other capture")

        app.buttons["showList"].tap()
        let row = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Patch the leak in the dinghy")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the sentence captured right after launch must land as an inkling")
        attachScreenshot(app, name: "00-auto-listening-saved")
    }

    func testCaptureEditSaveAndSeeInList() throws {
        let app = XCUIApplication()
        app.launch()

        // Permission dialogs are pre-granted for this build in CI; if they
        // appear anyway (e.g. a fresh simulator), dismiss them so the flow
        // continues instead of hanging. Requested automatically on launch now
        // that the app is voice-first, so this has to happen before anything
        // else, not after a tap.
        dismissSystemAlertIfPresent(app)
        dismissSystemAlertIfPresent(app) // speech recognition, then microphone

        attachScreenshot(app, name: "01-idle")

        let inkwell = app.otherElements["inkwell"]
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))

        // Counted before and after rather than asserted as "exactly one", so
        // the duplicate check at the end means the same thing on a simulator
        // that already has captures on disk from an earlier run.
        let rowsBefore = countCaptureRows(app)

        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5), "capture must already be listening on launch, with no tap required")
        attachScreenshot(app, name: "02-listening")

        transcript.tap()

        let editor = app.textViews["transcriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("Rig a tide-powered charger for the buoy sensors so they never need a battery run.")
        dismissKeyboardTipIfPresent(app)
        attachScreenshot(app, name: "03-editing")

        let doneButton = app.buttons["keyboardDone"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.tap()

        let toast = app.staticTexts["confirmationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "04-confirmation")

        // Back to idle once the toast clears.
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5))

        // The saved draft is really let go, not just hidden behind the toast:
        // a Done button still sitting on the idle screen means the words are
        // still readable as content, and tapping it saves them a second time.
        XCTAssertTrue(app.staticTexts["Tap the well to begin"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["done"].exists, "the idle screen after a save must not offer Done again")
        XCTAssertFalse(app.buttons["Discard"].exists, "nothing is left to discard once the capture is saved")
        attachScreenshot(app, name: "06-idle-after-save")

        app.buttons["showList"].tap()
        XCTAssertTrue(captureRows(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(
            captureRows(app).count, rowsBefore + 1,
            "one capture must land in the well once, not twice"
        )
        attachScreenshot(app, name: "05-list")
    }

    /// Opens the well, counts this capture's rows, and closes it again,
    /// leaving the app back on the screen it was called from.
    private func countCaptureRows(_ app: XCUIApplication) -> Int {
        app.buttons["showList"].tap()
        XCTAssertTrue(app.navigationBars["The well"].waitForExistence(timeout: 5))
        let count = captureRows(app).count
        app.buttons["Close"].tap()
        XCTAssertTrue(app.otherElements["inkwell"].waitForExistence(timeout: 5))
        return count
    }

    private func captureRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Rig a tide-powered charger"))
    }
}
