import CoreText
import Foundation

/// Fonts for mpv's subtitle renderer (libass).
///
/// MPVUI ships no fonts and libass can't see the iPhone's system fonts by itself, so text
/// subtitles (SRT, WebVTT, and ASS without embedded fonts) had nothing to draw with and
/// stayed invisible. MPVUI's documented fix: give mpv a folder of font files (`sub-fonts-dir`)
/// and the family to use (`sub-font`). The folder holds links to the iPhone's own fonts
/// (found through Core Text, nothing downloaded or bundled): Helvetica Neue for Latin,
/// Cyrillic and Greek text, Hiragino Sans for Japanese, Apple SD Gothic Neo for Korean.
enum SubtitleFonts {
    struct Setup {
        let directory: String
        let family: String
    }

    /// PostScript names, primary family first.
    private static let wanted = [
        "HelveticaNeue", "HelveticaNeue-Bold",
        "HiraginoSans-W3", "HiraginoSans-W6",
        "AppleSDGothicNeo-Regular",
    ]
    /// libass reads every file in the folder into memory: skip anything huge.
    private static let maxFileBytes: Int64 = 40 * 1024 * 1024

    @MainActor private static var cached: Setup?

    @MainActor static func prepare() -> Setup? {
        if let cached, FileManager.default.fileExists(atPath: cached.directory) { return cached }
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("SubtitleFonts", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var family: String?
        var linkedFiles = Set<String>()
        for name in wanted {
            let font = CTFontCreateWithName(name as CFString, 24, nil)
            // Core Text substitutes a default font for unknown names: only take exact matches.
            guard (CTFontCopyPostScriptName(font) as String) == name,
                  let source = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { continue }
            if family == nil { family = CTFontCopyFamilyName(font) as String }
            let fileName = source.lastPathComponent
            guard !linkedFiles.contains(fileName) else { continue }   // weights often share one .ttc
            let size = (try? fm.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= maxFileBytes else { continue }
            let dest = dir.appendingPathComponent(fileName)
            if !fm.fileExists(atPath: dest.path) {          // follows links: a broken link is recreated
                try? fm.removeItem(at: dest)
                if (try? fm.createSymbolicLink(at: dest, withDestinationURL: source)) == nil {
                    try? fm.copyItem(at: source, to: dest)
                }
            }
            if fm.fileExists(atPath: dest.path) { linkedFiles.insert(fileName) }
        }
        guard let family, !linkedFiles.isEmpty else { return nil }
        let setup = Setup(directory: dir.path, family: family)
        cached = setup
        return setup
    }
}
