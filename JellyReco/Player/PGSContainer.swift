import Foundation

/// Wraps a PGS (.sup) subtitle stream in a minimal Matroska file with a single S_HDMV/PGS track.
///
/// Why: the player library's libmpv can't open standalone .sup files (its ffmpeg has no SUP
/// reader) and its MKV reader can't read zlib-compressed tracks, which is how MKVToolNix
/// stores PGS by default. Jellyfin's own ffmpeg reads those tracks and serves the original,
/// uncompressed PGS stream; this puts that stream in a container mpv reads natively. The
/// subtitle data itself is untouched (no conversion, no OCR, nothing burned in).
///
/// Foundation only, so CI compiles this exact file into a command-line test.
enum PGSContainer {

    /// One PGS display set (all segments from a presentation composition to its END).
    private struct DisplaySet { var milliseconds: UInt64; var payload: Data }

    /// Returns a .mks (Matroska subtitles) file, or nil if `sup` isn't a PGS stream.
    static func matroska(fromSUP sup: Data, language: String = "und") -> Data? {
        let bytes = [UInt8](sup)
        var sets: [DisplaySet] = []
        var current: DisplaySet?
        var p = 0
        while p + 13 <= bytes.count {
            // Segment header: "PG", PTS (4), DTS (4), type (1), size (2), then the data.
            guard bytes[p] == 0x50, bytes[p + 1] == 0x47 else { return sets.isEmpty ? nil : build(sets, language) }
            let pts = UInt64(bytes[p + 2]) << 24 | UInt64(bytes[p + 3]) << 16 | UInt64(bytes[p + 4]) << 8 | UInt64(bytes[p + 5])
            let type = bytes[p + 10]
            let size = Int(bytes[p + 11]) << 8 | Int(bytes[p + 12])
            let end = p + 13 + size
            guard end <= bytes.count else { break }
            // In Matroska the PGS block holds the segments without the 10-byte "PG"+timestamps header.
            let segment = Data(bytes[(p + 10)..<end])
            if type == 0x16 || current == nil {          // presentation composition = new display set
                if let c = current, !c.payload.isEmpty { sets.append(c) }
                current = DisplaySet(milliseconds: pts / 90, payload: Data())
            }
            current?.payload.append(segment)
            if type == 0x80, let c = current {            // END of display set
                sets.append(c)
                current = nil
            }
            p = end
        }
        if let c = current, !c.payload.isEmpty { sets.append(c) }
        return sets.isEmpty ? nil : build(sets, language)
    }

    private static func build(_ sets: [DisplaySet], _ language: String) -> Data {
        var out = Data()
        out += element(0x1A45_DFA3,                       // EBML header
                       uint(0x4286, 1) + uint(0x42F7, 1) + uint(0x42F2, 4) + uint(0x42F3, 8)
                       + string(0x4282, "matroska") + uint(0x4287, 4) + uint(0x4285, 2))
        var segment = Data()
        segment += element(0x1549_A966,                   // Info
                           uint(0x2A_D7B1, 1_000_000) + string(0x4D80, "JellyReco") + string(0x5741, "JellyReco"))
        let track = uint(0xD7, 1) + uint(0x73C5, 1) + uint(0x83, 0x11) + uint(0x9C, 0)
            + string(0x86, "S_HDMV/PGS") + string(0x22_B59C, language)
        segment += element(0x1654_AE6B, element(0xAE, track))   // Tracks > TrackEntry
        for set in sets {
            // SimpleBlock: track 1, relative timecode 0, keyframe flag, then the segments.
            let block = Data([0x81, 0x00, 0x00, 0x80]) + set.payload
            segment += element(0x1F43_B675, uint(0xE7, set.milliseconds) + element(0xA3, block))
        }
        out += id(0x1853_8067) + Data([0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // Segment size placeholder
        let sizeOffset = out.count - 7
        out += segment
        // Write the real segment size (8-byte EBML size: 0x01 marker + 7 bytes).
        let n = UInt64(segment.count)
        for k in 0..<7 { out[sizeOffset + k] = UInt8((n >> (8 * UInt64(6 - k))) & 0xFF) }
        return out
    }

    // MARK: EBML

    private static func id(_ value: UInt32) -> Data {
        let count = value > 0xFF_FFFF ? 4 : value > 0xFFFF ? 3 : value > 0xFF ? 2 : 1
        return Data((0..<count).reversed().map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    private static func size(_ n: Int) -> Data {
        // Always 8 bytes: 0x01 followed by the length in 7 bytes (valid EBML, simple).
        var d = Data([0x01])
        for k in (0..<7).reversed() { d.append(UInt8((UInt64(n) >> (8 * UInt64(k))) & 0xFF)) }
        return d
    }

    private static func element(_ elementID: UInt32, _ body: Data) -> Data { id(elementID) + size(body.count) + body }

    private static func uint(_ elementID: UInt32, _ value: UInt64) -> Data {
        var bytes: [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        return element(elementID, Data(bytes))
    }

    private static func string(_ elementID: UInt32, _ value: String) -> Data { element(elementID, Data(value.utf8)) }
}
