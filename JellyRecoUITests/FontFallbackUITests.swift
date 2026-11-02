import XCTest

/// Which characters libass can't find a font for with the app's subtitle fonts (iOS simulator,
/// the same iOS fonts and libmpv as the phone). Report only.
final class FontFallbackUITests: XCTestCase {
    func testSubtitleFontFallbacks() throws {
        guard let base = ProcessInfo.processInfo.environment["JELLYRECO_SAMPLES_URL"] else {
            throw XCTSkip("JELLYRECO_SAMPLES_URL not set")
        }
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = "fonttest"
        app.launchEnvironment["JELLYRECO_SAMPLE"] = "\(base)/render_srt.mkv"
        app.launch()
        let state = app.staticTexts["fonttest-state"]
        let done = expectation(for: NSPredicate(format: "label BEGINSWITH 'READY' OR label BEGINSWITH 'FAIL'"), evaluatedWith: state)
        wait(for: [done], timeout: 60)
        for part in state.label.components(separatedBy: " || ") {
            print("RESULT fonttest: \(part)")
        }
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = "fonttest"
        a.lifetime = .keepAlways
        add(a)
    }
}
