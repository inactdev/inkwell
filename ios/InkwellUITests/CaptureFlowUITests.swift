import XCTest

/// Drives the real capture flow through the actual UI - not a unit test of
/// the view model - and attaches a screenshot at each stage so the outcome
/// can be judged visually. The simulator has no live speaker in this
/// environment, so dictation stays on its "Listening…" placeholder; typed
/// text stands in for what a human would have said, exercising the same
/// edit-and-save path either way.
@MainActor
final class CaptureFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureEditSaveAndSeeInList() throws {
        let app = XCUIApplication()
        app.launch()

        attachScreenshot(app, name: "01-idle")

        let inkwell = app.otherElements["inkwell"]
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))

        // Counted before and after rather than asserted as "exactly one", so
        // the duplicate check at the end means the same thing on a simulator
        // that already has captures on disk from an earlier run.
        let rowsBefore = countCaptureRows(app)

        inkwell.tap()

        // Permission dialogs are pre-granted for this build in CI; if they
        // appear anyway (e.g. a fresh simulator), dismiss them so the flow
        // continues instead of hanging.
        dismissSystemAlertIfPresent(app)

        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
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
