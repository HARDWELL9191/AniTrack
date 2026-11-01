import XCTest

/// Picture subtitles (PGS, DVB, VobSub) on the native video layer, the battery-friendly path the
/// player now uses for them, with the Metal renderer and an ASS file as references. Each file has a
/// black picture and a bright caption, so bright pixels in the picture's lower half = subtitle.
final class SubtitleRenderUITests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func captionPixels(_ shot: XCUIScreenshot) -> Int {
        guard let cg = shot.image.cgImage else { return -1 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = data.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return -1 }
        // Lower half of the screen, above the home indicator.
        var count = 0
        for y in (h / 2)..<(h * 92 / 100) {
            for x in 0..<w {
                let i = (y * w + x) * 4
                if max(data[i], data[i + 1], data[i + 2]) > 120 { count += 1 }
            }
        }
        return count
    }

    func testPictureSubtitlesOnNativeLayer() throws {
        guard let base = ProcessInfo.processInfo.environment["JELLYRECO_SAMPLES_URL"] else {
            throw XCTSkip("JELLYRECO_SAMPLES_URL not set")
        }
        let files = ["render_pgs.mkv", "render_dvb.ts", "render_vobsub.mkv", "render_ass_colored.mkv"]
        for file in files {
            for output in ["native"] {   // Metal is covered by the formats job (mpv drawing the same files)
                let app = XCUIApplication()
                app.launchEnvironment["JELLYRECO_UITEST"] = "subrender"
                app.launchEnvironment["JELLYRECO_SAMPLE"] = "\(base)/\(file)"
                app.launchEnvironment["JELLYRECO_OUTPUT"] = output
                app.launch()
                let state = app.staticTexts["subrender-state"]
                let pred = NSPredicate(format: "label BEGINSWITH 'READY' OR label BEGINSWITH 'FAIL'")
                let done = expectation(for: pred, evaluatedWith: state)
                wait(for: [done], timeout: 50)
                let shot = XCUIScreen.main.screenshot()
                let a = XCTAttachment(screenshot: shot)
                a.name = "subrender-\(file)-\(output)"
                a.lifetime = .keepAlways
                add(a)
                let label = state.label
                // Metal: counted on the screenshot. Native: the simulator's screenshots leave the
                // native video layer out, so the app reads back the frame that layer is showing.
                let pixels: Int
                if output == "native" {
                    let n = label.range(of: #"best=brightpx:(\d+)"#, options: .regularExpression)
                        .map { Int(label[$0].dropFirst(14)) ?? -1 } ?? -1
                    pixels = n
                } else {
                    pixels = captionPixels(shot)
                }
                print("RESULT subrender \(file) \(output): \(pixels) caption pixels | \(label)")
                // The fix under test: the native layer must draw picture subtitles itself.
                if output == "native" {
                    XCTAssertGreaterThan(pixels, 1500, "\(file) on the native layer: no subtitle drawn")
                }
                app.terminate()
            }
        }
    }
}
