import XCTest

/// For You on the Anime / Anime Movies libraries: the ported AniReco recommender against real
/// AniList (a made-up list, no account), checked in the app itself.
final class AniListRecoUITests: XCTestCase {
    func testAniListPicks() {
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = "anilist-reco"
        app.launch()
        let result = app.staticTexts["anilist-result"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), "result text")
        let done = NSPredicate(format: "label BEGINSWITH 'ANILIST P' OR label BEGINSWITH 'ANILIST F'")
        expectation(for: done, evaluatedWith: result)
        waitForExpectations(timeout: 420)
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "anilist-reco"
        a.lifetime = .keepAlways
        add(a)
        print("RESULT anilist: \(result.label)")
        XCTAssertTrue(result.label.hasPrefix("ANILIST PASS"), result.label)
    }
}
