import XCTest

/// Anime lists, Movie list and the AniReco pick card (screenshots for review).
final class ListsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = mode
        app.launch()
        let state = app.staticTexts["lists-state"]
        XCTAssertTrue(state.waitForExistence(timeout: 30))
        let done = NSPredicate(format: "label == 'LISTS ready' OR label BEGINSWITH 'LISTS FAIL'")
        expectation(for: done, evaluatedWith: state)
        waitForExpectations(timeout: 90)
        print("RESULT lists \(mode): \(state.label)")
        sleep(3)
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testAnimeLists() {
        let app = launch("lists-anime")
        shot(app, "anime-lists")
        app.buttons["Lists"].firstMatch.tap()
        sleep(1)
        shot(app, "anime-lists-menu")
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Completed'")).firstMatch.tap()
        sleep(2)
        shot(app, "anime-lists-completed")
        app.buttons["Filter"].firstMatch.tap()
        sleep(1)
        shot(app, "anime-lists-filter")
        // Close the menu by tapping the title area, then let it animate away.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        sleep(2)
        app.buttons["Sort"].firstMatch.tap()
        sleep(2)
        shot(app, "anime-lists-sort")
    }

    func testMovieList() {
        let app = launch("lists-movies")
        shot(app, "movie-list")
        app.buttons["Genre"].firstMatch.tap()
        sleep(1)
        shot(app, "movie-list-genre")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        sleep(2)
        app.buttons["Sort"].firstMatch.tap()
        sleep(2)
        shot(app, "movie-list-sort")
    }

    func testLongTitleDetails() {
        let app = launch("lists-detail")
        app.buttons["Open details"].firstMatch.tap()
        sleep(4)
        shot(app, "detail-long-title")
        // The sheet must fit the screen: every text in it starts and ends inside the window.
        let window = app.windows.firstMatch.frame
        for view in app.textViews.allElementsBoundByIndex where view.exists {
            print("RESULT detail text \(view.frame) window \(window)")
            XCTAssertGreaterThanOrEqual(view.frame.minX, window.minX - 1, "Details sheet is wider than the screen")
            XCTAssertLessThanOrEqual(view.frame.maxX, window.maxX + 1, "Details sheet is wider than the screen")
        }
    }

    func testPickCard() {
        let app = launch("lists-pick")
        shot(app, "anime-pick-card")
    }
}
