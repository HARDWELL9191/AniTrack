import XCTest

/// The Identify sheet (details page ⋯ menu): search form, provider ids, results, the confirm page.
final class IdentifyUITests: XCTestCase {
    func testIdentifySheet() {
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = "identify"
        app.launch()
        XCTAssertTrue(app.navigationBars["Identify"].waitForExistence(timeout: 30))
        shot(app, "identify-form")
        app.swipeUp()
        sleep(1)
        shot(app, "identify-results")
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'WorldEnd'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(app.switches["Replace existing images"].waitForExistence(timeout: 5))
        shot(app, "identify-confirm")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
