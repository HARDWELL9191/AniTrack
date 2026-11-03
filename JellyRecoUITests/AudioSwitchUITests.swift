import XCTest

/// Reproduces "audio stops after switching audio tracks": the app's player switches through six
/// audio tracks in several patterns and reports what mpv says after each switch.
final class AudioSwitchUITests: XCTestCase {
    func testAudioTrackSwitching() throws {
        guard let base = ProcessInfo.processInfo.environment["JELLYRECO_SAMPLES_URL"] else {
            throw XCTSkip("JELLYRECO_SAMPLES_URL not set")
        }
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = "audioswitch"
        app.launchEnvironment["JELLYRECO_SAMPLE"] = "\(base)/audio_switch.mkv"
        app.launch()
        let state = app.staticTexts["audioswitch-state"]
        let done = expectation(for: NSPredicate(format: "label BEGINSWITH 'READY' OR label BEGINSWITH 'FAIL'"), evaluatedWith: state)
        wait(for: [done], timeout: 150)
        for part in state.label.components(separatedBy: " ## ") { print("RESULT audioswitch \(part)") }
        app.terminate()
    }
}
