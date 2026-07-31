import XCTest

/// Proves the product contract's central guarantee end to end: a capture
/// made with the backend completely unreachable still lands locally, and
/// hands itself over quietly once the backend comes back - no retry
/// button, no error, just the "not yet synced" indicator clearing on its
/// own. The backend's availability during this test is controlled entirely
/// from outside the test process (see backend/README.md's e2e script);
/// this test only observes the phone side.
@MainActor
final class OfflineSyncUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureOfflineThenSyncsWhenBackendReturns() throws {
        let app = XCUIApplication()
        app.launch()

        let inkwell = app.otherElements["inkwell"]
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))
        inkwell.tap()
        dismissSystemAlertIfPresent(app)

        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.tap()

        let editor = app.textViews["transcriptEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText(Self.probeText)
        dismissKeyboardTipIfPresent(app)

        let doneButton = app.buttons["keyboardDone"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3))
        doneButton.tap()

        let toast = app.staticTexts["confirmationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 3))
        XCTAssertTrue(inkwell.waitForExistence(timeout: 5))

        // The backend is not running yet at this point - confirm the
        // capture landed locally anyway, marked as not yet synced.
        let unsyncedBadge = app.staticTexts["unsyncedCount"]
        XCTAssertTrue(unsyncedBadge.waitForExistence(timeout: 3), "capture should be visible as unsynced while the backend is down")
        attachScreenshot(app, name: "offline-1-captured-unsynced")

        app.buttons["showList"].tap()
        let unsyncedRow = app.staticTexts["not yet synced"].firstMatch
        XCTAssertTrue(unsyncedRow.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "offline-2-list-unsynced")
        app.buttons["Close"].tap()

        // The external orchestrator starts the backend some seconds into
        // this run (see backend's e2e script) - poll for the sync
        // coordinator's next pass (foreground timer + reachability probe)
        // to notice and clear the indicator. No manual retry is triggered
        // from the test; this is the same quiet, automatic path the owner
        // would see.
        let badgeGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: unsyncedBadge)
        wait(for: [badgeGone], timeout: 90)
        attachScreenshot(app, name: "offline-3-synced")

        app.buttons["showList"].tap()
        let allSynced = app.staticTexts["All synced"]
        XCTAssertTrue(allSynced.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "offline-4-list-synced")
    }

    static let probeText = "Offline sync probe: message in a bottle for the harbor buoy."
}
