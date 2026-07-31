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

        app.buttons["showList"].tap()
        let firstRow = app.staticTexts["Rig a tide-powered charger for the buoy sensors so they neve…"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "05-list")
    }
}
