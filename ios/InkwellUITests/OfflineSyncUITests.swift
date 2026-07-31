import XCTest

/// Proves the product contract's central guarantee end to end: a capture
/// made while the backend is genuinely unreachable - hung, not refused -
/// still lands locally, and hands itself over quietly once the backend
/// becomes reachable, with no retry button, no error, and no relaunch.
///
/// Deliberately a timeout, not a connection refusal: on a subway, a dropped
/// connection doesn't answer "connection refused" - it just never answers.
/// Those take very different amounts of time to fail (see
/// SyncCoordinator.swift's own explicit request timeout), so a test built
/// around stopping and starting the real backend would prove the wrong
/// thing - refusal fails in milliseconds and never exercises the timeout
/// path at all.
///
/// tools/blackhole-proxy stands in for the backend here: a connection
/// accepted during its fixed window is held open and silent forever - a
/// genuine black hole, ended only by the client's own timeout, never
/// answered late - while one opened after that window reaches the real
/// backend, with no external signal needed.
/// `dev.sh ios test` launches it and bakes its URL into the Test scheme
/// (see project.yml); this test reads that and points the app at it via
/// launchEnvironment before app.launch(), since XCUIApplication().launch()
/// does not reliably inherit the scheme's own environment variables (see
/// AppConfig.swift).
@MainActor
final class OfflineSyncUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureHangsThenSyncsWhenBackendBecomesReachable() throws {
        guard let proxyURL = ProcessInfo.processInfo.environment["INKWELL_TEST_PROXY_URL"] else {
            XCTFail("INKWELL_TEST_PROXY_URL not set - run via `./dev.sh ios test`, which launches tools/blackhole-proxy and bakes this in")
            return
        }

        let app = XCUIApplication()
        app.launchEnvironment["INKWELL_BACKEND_URL"] = proxyURL
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

        // The proxy is black-holing every connection right now, and the
        // app's own sync attempt should be hung inside its own short,
        // explicit request timeout - not crashed, not frozen, just quietly
        // unsynced while the attempt plays out in the background.
        let unsyncedBadge = app.staticTexts["unsyncedCount"]
        XCTAssertTrue(unsyncedBadge.waitForExistence(timeout: 3), "capture should be visible as unsynced while the backend is a black hole")
        XCTAssertTrue(app.otherElements["inkwell"].isHittable, "the UI must stay responsive while a sync attempt is hanging in the background")
        attachScreenshot(app, name: "offline-1-captured-unsynced")

        app.buttons["showList"].tap()
        let unsyncedRow = app.staticTexts["not yet synced"].firstMatch
        XCTAssertTrue(unsyncedRow.waitForExistence(timeout: 3))
        attachScreenshot(app, name: "offline-2-list-unsynced")
        app.buttons["Close"].tap()

        // No relaunch, no retry button, nothing but time passing: the proxy
        // opens up on its own clock, and the app's own periodic sync pass
        // picks it up.
        // 45s is the regression guard, not a round number: with the explicit
        // 10s request timeout the first attempt dies inside the window and a
        // later periodic pass (every 20s) lands once the proxy opens, well
        // inside this. On URLSession's 60s default the black-holed first
        // connection is never resolved at all, so the app would still be
        // waiting on it here and this would - correctly - fail.
        let badgeGone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: unsyncedBadge)
        wait(for: [badgeGone], timeout: 45)
        attachScreenshot(app, name: "offline-3-synced")

        app.buttons["showList"].tap()
        let allSynced = app.staticTexts["All synced"]
        XCTAssertTrue(allSynced.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "offline-4-list-synced")
    }

    static let probeText = "Offline sync probe: message in a bottle for the harbor buoy."
}
