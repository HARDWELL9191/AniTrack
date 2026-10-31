import XCTest

/// The real settings screens in the simulator, tapped like a finger, with screenshots.
final class SettingsPagesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func launch(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["JELLYRECO_UITEST"] = mode
        app.launch()
        return app
    }

    /// Scrolls down until the element is on screen (lists only create rows near the screen).
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, swipes: Int = 12) -> Bool {
        for _ in 0..<swipes {
            if element.exists && element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists
    }

    private func toTop(_ app: XCUIApplication) {
        for _ in 0..<12 { app.swipeDown(velocity: .fast) }
    }

    private func startsWith(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
    }

    func testTranscodingQuickSyncLikeJellyfin() {
        let app = launch("transcoding")
        XCTAssertTrue(app.navigationBars["Transcoding"].waitForExistence(timeout: 30), "page")
        shot(app, "transcoding-qsv-1-top")
        XCTAssertFalse(startsWith(app, "Hardware decoding codecs").exists, "old one-per-line text box must be gone")

        // QSV: jellyfin-web's decoding list for Intel, each its own switch.
        let expected: [(String, String)] = [("H264", "1"), ("HEVC", "1"), ("MPEG2", "1"), ("VC1", "1"), ("VP8", "0"),
                                            ("VP9", "1"), ("AV1", "1"), ("HEVC 10bit", "1"), ("VP9 10bit", "1")]
        var shotIndex = 2
        for (name, value) in expected {
            let sw = app.switches[name]
            let found = reveal(app, sw)
            let actual = found ? (sw.value as? String ?? "?") : "missing"
            print("RESULT transcoding qsv switch \(name): \(actual) (expected \(value))")
            XCTAssertTrue(found, "switch \(name)")
            XCTAssertEqual(actual, value, name)
            if name == "VP8" || name == "VP9 10bit" { shot(app, "transcoding-qsv-\(shotIndex)-switches"); shotIndex += 1 }
        }
        XCTAssertFalse(app.switches["MPEG4"].exists, "MPEG4 isn't offered for QSV in jellyfin-web")

        // Turning one on works and only that row changes.
        let vp8 = app.switches["VP8"]
        if reveal(app, vp8) {
            vp8.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            print("RESULT VP8 after tap: \(vp8.value as? String ?? "?"); H264 still \(app.switches["H264"].value as? String ?? "?")")
            XCTAssertEqual(vp8.value as? String, "1")
            shot(app, "transcoding-qsv-\(shotIndex)-vp8-on"); shotIndex += 1
        }

        XCTAssertTrue(reveal(app, startsWith(app, "Prefer OS native DXVA")), "QSV-only option")
        XCTAssertFalse(startsWith(app, "Enable enhanced NVDEC").exists, "NVENC-only option must be hidden for QSV")
        XCTAssertTrue(reveal(app, startsWith(app, "Enable Intel Low-Power H.264")), "QSV/VAAPI option")
        XCTAssertTrue(reveal(app, startsWith(app, "Enable VPP tone mapping")), "VPP section for QSV")
        shot(app, "transcoding-qsv-\(shotIndex)-encoding"); shotIndex += 1
        reveal(app, startsWith(app, "Transcoding thread count"))
        shot(app, "transcoding-qsv-\(shotIndex)-transcoding"); shotIndex += 1
        app.swipeUp(); app.swipeUp()
        shot(app, "transcoding-qsv-\(shotIndex)-bottom")

        // Switch the dropdown to NVENC, like a finger: the page follows the type.
        toTop(app)
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Hardware acceleration' OR label CONTAINS 'Quicksync' OR value CONTAINS 'Quicksync'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "acceleration dropdown")
        let title = app.staticTexts["Hardware acceleration"].firstMatch
        print("RESULT dropdown label: \(picker.label) value: \(picker.value as? String ?? "") frame \(picker.frame) title frame \(title.frame)")
        // Apple's layout: the value sits on the title's line, on the right.
        XCTAssertTrue(title.exists && abs(picker.frame.midY - title.frame.midY) < 30 && picker.frame.minX > title.frame.minX,
                      "dropdown value beside its title")
        picker.tap()
        shot(app, "transcoding-dropdown-open")
        let nvenc = app.buttons["Nvidia NVENC"]
        XCTAssertTrue(nvenc.waitForExistence(timeout: 5), "NVENC option")
        nvenc.tap()
        XCTAssertFalse(startsWith(app, "QSV device").waitForExistence(timeout: 2), "QSV device hidden for NVENC")
        let mpeg4 = app.switches["MPEG4"]
        XCTAssertTrue(reveal(app, mpeg4), "MPEG4 offered for NVENC")
        XCTAssertTrue(reveal(app, startsWith(app, "Enable enhanced NVDEC")), "NVENC-only option")
        print("RESULT after NVENC: MPEG4 \(mpeg4.exists), NVDEC \(startsWith(app, "Enable enhanced NVDEC").exists), Save enabled \(app.buttons["Save"].isEnabled)")
        shot(app, "transcoding-nvenc")
    }

    func testDashboardMenuLikeDesktop() {
        let app = launch("dashboard")
        XCTAssertTrue(app.navigationBars["Dashboard"].waitForExistence(timeout: 30))
        shot(app, "dashboard-1")
        let items = ["Dashboard", "General", "Branding", "Users", "Libraries", "Display", "Metadata", "NFO settings",
                     "Transcoding", "Resume", "Streaming", "Trickplay", "Devices", "Activity", "Live TV", "DVR",
                     "My plugins", "Catalog", "Repositories", "Networking", "API keys", "Backups", "Logs", "Scheduled tasks"]
        var missing: [String] = []
        for name in items where !reveal(app, app.buttons[name].firstMatch, swipes: 6) && !reveal(app, app.staticTexts[name].firstMatch, swipes: 2) {
            missing.append(name)
        }
        shot(app, "dashboard-2")
        print("RESULT dashboard missing items: \(missing)")
        XCTAssertEqual(missing, [])
    }

    func testSettingsSectionsLikeDesktop() {
        let app = launch("settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30))
        shot(app, "settings-1")
        var missing: [String] = []
        for name in ["Display", "Home", "Playback", "Player", "Subtitles", "For You", "Devices & servers", "About"]
        where !reveal(app, app.buttons[name].firstMatch, swipes: 4) {
            missing.append(name)
        }
        print("RESULT settings missing: \(missing)")
        XCTAssertEqual(missing, [])
        for page in ["Playback", "Player", "Subtitles", "Display"] {
            toTop(app)
            let link = app.buttons[page].firstMatch
            guard reveal(app, link, swipes: 4) else { continue }
            link.tap()
            _ = app.navigationBars[page].waitForExistence(timeout: 5)
            shot(app, "settings-\(page)-1")
            app.swipeUp(); shot(app, "settings-\(page)-2")
            app.swipeUp(); shot(app, "settings-\(page)-3")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }
}
