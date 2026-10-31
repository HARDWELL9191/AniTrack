import XCTest

/// Reproduces "nothing happens when tapping Save and find picks": types a key with the
/// keyboard up and taps the button like a finger would. A fake key must produce TMDB's
/// rejection message (proof the button ran); nothing at all = the tap was lost.
final class TMDBKeyCardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func run(_ mode: String) {
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = mode
        app.launch()
        let field = app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30), "key field")
        field.tap()
        field.typeText("0123456789abcdef0123456789abcdef")
        shot(app, "\(mode)-1-typed")
        print("KEYBOARD \(mode): \(app.keyboards.firstMatch.exists ? "up" : "not shown")")

        let save = app.buttons["Save and find picks"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button")
        save.tap()
        shot(app, "\(mode)-2-just-tapped")
        let error = app.staticTexts["tmdb-error"]
        let ran = error.waitForExistence(timeout: 25)
        shot(app, "\(mode)-3-after")
        print("RESULT \(mode) first tap: \(ran ? "button ran -> \(error.label)" : "NOTHING HAPPENED")")
        print("STATE \(mode): \(app.staticTexts["tmdb-state"].label)")
        if !ran {
            save.tap()
            let ran2 = error.waitForExistence(timeout: 25)
            shot(app, "\(mode)-4-second-tap")
            print("RESULT \(mode) second tap: \(ran2 ? "button ran -> \(error.label)" : "NOTHING HAPPENED")")
        }
        app.terminate()
    }

    func testOldBuild() { run("tmdb-old") }
    func testNewBuild() { run("tmdb-new") }
}
