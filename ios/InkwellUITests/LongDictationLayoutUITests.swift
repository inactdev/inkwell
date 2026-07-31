import XCTest

/// Regression coverage for a review finding: `promptOrTranscript` had no
/// height ceiling while listening, so a long ramble pushed the newest words
/// below the screen edge with no way to see or scroll to them - unacceptable
/// for a tool whose entire job is capturing what the owner just said aloud.
///
/// The headless simulator never produces a real transcript from speech, so
/// this reaches the exact same rendering path - the `.listening` case's
/// `Text(viewModel.displayedText)`, inside the shared scrollable container -
/// through a legitimate sequence of real UI interactions rather than a
/// test-only hook: type a long passage while editing, then tap "Resume
/// dictation." `resumeDictation()` re-enters `.listening` without touching
/// `committedText`, so the just-typed passage becomes what that Text view
/// renders as "live" - reproducing the reported scenario exactly, using only
/// interactions an owner could actually perform.
@MainActor
final class LongDictationLayoutUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLongDictationStaysScrollableAndTheHeaderStaysPut() throws {
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
        editor.typeText(Self.longRamble)
        dismissKeyboardTipIfPresent(app)

        let resumeButton = app.buttons["Resume dictation"]
        XCTAssertTrue(resumeButton.waitForExistence(timeout: 3))
        resumeButton.tap()
        dismissSystemAlertIfPresent(app)

        // Back in .listening with the long passage now rendered as the live
        // transcript - the exact case that had no height ceiling.
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        attachScreenshot(app, name: "long-dictation-01-scrolled")

        // Structural check, not just "exists in the tree": the header row
        // must still be within the visible screen and tappable - what the
        // original bug broke was exactly this, while the wordmark and tray
        // icon still technically "existed" above the status bar.
        XCTAssertTrue(app.buttons["showList"].isHittable, "the tray button must stay on-screen and tappable, not pushed above the status bar")

        // The tail of a long ramble is what the owner just said - it must be
        // scrolled into view automatically, not left below the screen edge.
        // The well scrolling out of view above to make room for it is
        // correct, not a regression: the two can't both be on-screen at once
        // once the passage is this long, and showing what was just said
        // matters more here than showing the well.
        let lastLine = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "the buoy will still be there tomorrow")).firstMatch
        XCTAssertTrue(lastLine.waitForExistence(timeout: 3), "the most recently spoken words must exist in the transcript")
        XCTAssertTrue(lastLine.isHittable, "the most recently spoken words must be scrolled into view, not left below the screen edge")

        // And scrolling back up still finds the well where it should be -
        // nothing about auto-scroll should strand it unreachably off-screen.
        app.swipeDown()
        XCTAssertTrue(inkwell.waitForExistence(timeout: 2), "the well must still be reachable by scrolling back up")

        // Clean up rather than leave a long draft (or save it) behind - the
        // footer's Discard is reachable directly from .listening.
        app.buttons["Discard"].tap()
    }

    private static let longRamble = """
        Okay so picture a buoy out past the harbor mouth, the kind that just \
        bobs there logging temperature and current. Rig a tide-powered charger \
        for it so the battery never has to be swapped by a boat trip. The float \
        itself could turn a small generator as it rises and falls twice a day, \
        nothing fancy, just enough to trickle-charge a capacitor bank. \
        Sensors only need to wake up every few minutes anyway so the draw is tiny. \
        Weatherproofing is the real problem, not the generator, everything else \
        about this is basically solved already by people who make wave energy \
        buoys at a much bigger scale. Maybe start with a scaled down rig in the \
        bathtub before anything goes near actual salt water. Corrosion will \
        probably kill the first three prototypes and that is fine, that is how \
        this always goes. Log the failures somewhere so the fourth attempt \
        actually learns something instead of repeating the same mistake. \
        Could also just buy a commercial one built for exactly this instead of \
        rigging something from scratch, worth pricing that out first honestly. \
        Either way none of this is urgent, the buoy will still be there tomorrow.
        """
}
