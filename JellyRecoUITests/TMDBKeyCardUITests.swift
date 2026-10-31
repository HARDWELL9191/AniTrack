import XCTest

/// The TMDB key flow on the real For You screen, tapped like a finger with the keyboard up.
final class TMDBKeyCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func enterKey(_ app: XCUIApplication, _ key: String, mode: String) {
        app.launchEnvironment["JELLYRECO_UITEST"] = mode
        app.launch()
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "key field")
        field.tap()
        field.typeText(key)
        shot(app, "\(mode)-1-typed")
        let save = app.buttons["Save and find picks"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button")
        save.tap()
    }

    /// A fake key: TMDB's rejection must appear (the button really runs).
    func testFakeKeyShowsTMDBError() {
        let app = XCUIApplication()
        enterKey(app, "0123456789abcdef0123456789abcdef", mode: "foryou")
        let error = app.staticTexts["tmdb-error"]
        let shown = error.waitForExistence(timeout: 25)
        shot(app, "fake-key-after")
        print("RESULT fake key: \(shown ? "error shown -> \(error.label)" : "NOTHING HAPPENED")")
        XCTAssertTrue(shown)
    }

    /// A valid key: the card must go away and For You must start working.
    func testValidKeyStartsForYou() {
        let app = XCUIApplication()
        enterKey(app, "uitestvalidkey0000000000000000000", mode: "foryou")
        let gone = app.secureTextFields.firstMatch.waitForNonExistence(timeout: 10)
        shot(app, "valid-key-after")
        let state = app.staticTexts["tmdb-state"].label
        print("RESULT valid key: card \(gone ? "replaced by For You" : "STILL SHOWN (nothing happened)"); \(state)")
        XCTAssertTrue(gone)
    }

    /// The old bug: For You's engine not connected (saved-account sign-in) = your symptom.
    func testOldBugReproduces() {
        let app = XCUIApplication()
        enterKey(app, "uitestvalidkey0000000000000000000", mode: "foryou-unattached")
        let gone = app.secureTextFields.firstMatch.waitForNonExistence(timeout: 10)
        shot(app, "old-bug-after")
        print("RESULT old bug: card \(gone ? "replaced" : "STILL SHOWN, no error (= reported symptom)"); \(app.staticTexts["tmdb-state"].label)")
    }
}
