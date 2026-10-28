import Foundation

/// Writes a real Excel workbook (.xlsx) with no third-party code: a few XML files packed in a
/// ZIP. One sheet per list, bold frozen header row with filters, real numbers and dates (so
/// sorting and sums work in Excel, Numbers and Google Sheets). Pure Foundation, so CI can
/// compile and check it on its own.
enum XLSXWriter {
    enum Cell {
        case text(String)
        case number(Double)
        case date(Date)
        /// A clickable link (shown as the address).
        case link(String)
        case empty
    }

    struct Column {
        let title: String
        let width: Double
    }

    struct Sheet {
        let name: String
        let columns: [Column]
        let rows: [[Cell]]
    }

    static func data(sheets: [Sheet]) -> Data {
        let sheets = uniqueNames(sheets)
        var files: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes(count: sheets.count).utf8)),
            ("_rels/.rels", Data(rootRels.utf8)),
            ("xl/workbook.xml", Data(workbook(sheets).utf8)),
            ("xl/_rels/workbook.xml.rels", Data(workbookRels(count: sheets.count).utf8)),
            ("xl/styles.xml", Data(styles.utf8))
        ]
        for (index, sheet) in sheets.enumerated() {
            files.append(("xl/worksheets/sheet\(index + 1).xml", Data(worksheet(sheet).utf8)))
        }
        return Zip.archive(files)
    }

    // MARK: Parts

    private static let mainNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    private static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

    private static func contentTypes(count: Int) -> String {
        var s = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        s += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        s += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        s += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        s += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        for i in 0..<count {
            s += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        return s + "</Types>"
    }

    private static let rootRels = header
        + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        + "</Relationships>"

    private static func workbook(_ sheets: [Sheet]) -> String {
        var s = header + "<workbook xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\"><bookViews><workbookView/></bookViews><sheets>"
        for (i, sheet) in sheets.enumerated() {
            s += "<sheet name=\"\(escape(sheet.name))\" sheetId=\"\(i + 1)\" r:id=\"rId\(i + 1)\"/>"
        }
        s += "</sheets><definedNames>"
        for (i, sheet) in sheets.enumerated() where !sheet.columns.isEmpty {
            // The filter range, so Excel keeps the header filters working.
            let quoted = "'" + sheet.name.replacingOccurrences(of: "'", with: "''") + "'"
            let last = columnName(sheet.columns.count - 1)
            s += "<definedName name=\"_xlnm._FilterDatabase\" localSheetId=\"\(i)\" hidden=\"1\">"
                + escape("\(quoted)!$A$1:$\(last)$\(sheet.rows.count + 1)") + "</definedName>"
        }
        return s + "</definedNames></workbook>"
    }

    private static func workbookRels(count: Int) -> String {
        var s = header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for i in 0..<count {
            s += "<Relationship Id=\"rId\(i + 1)\" Type=\"\(relNS)/worksheet\" Target=\"worksheets/sheet\(i + 1).xml\"/>"
        }
        s += "<Relationship Id=\"rId\(count + 1)\" Type=\"\(relNS)/styles\" Target=\"styles.xml\"/>"
        return s + "</Relationships>"
    }

    /// Styles: 0 normal, 1 bold header, 2 date, 3 link, 4 number with one decimal.
    private static let styles = header
        + "<styleSheet xmlns=\"\(mainNS)\">"
        + "<numFmts count=\"1\"><numFmt numFmtId=\"164\" formatCode=\"0.0\"/></numFmts>"
        + "<fonts count=\"3\">"
        + "<font><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        + "<font><b/><sz val=\"11\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        + "<font><u/><sz val=\"11\"/><color rgb=\"FF0563C1\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        + "</fonts>"
        + "<fills count=\"3\"><fill><patternFill patternType=\"none\"/></fill><fill><patternFill patternType=\"gray125\"/></fill>"
        + "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFF2E6EE\"/><bgColor indexed=\"64\"/></patternFill></fill></fills>"
        + "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        + "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"
        + "<cellXfs count=\"5\">"
        + "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        + "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"2\" borderId=\"0\" xfId=\"0\" applyFont=\"1\" applyFill=\"1\"/>"
        + "<xf numFmtId=\"14\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        + "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        + "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        + "</cellXfs>"
        + "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        + "</styleSheet>"

    private static func worksheet(_ sheet: Sheet) -> String {
        let columnCount = max(sheet.columns.count, 1)
        let last = columnName(columnCount - 1)
        let lastRow = sheet.rows.count + 1
        var s = header + "<worksheet xmlns=\"\(mainNS)\" xmlns:r=\"\(relNS)\">"
        s += "<dimension ref=\"A1:\(last)\(lastRow)\"/>"
        s += "<sheetViews><sheetView workbookViewId=\"0\">"
            + "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
            + "<selection pane=\"bottomLeft\" activeCell=\"A2\" sqref=\"A2\"/></sheetView></sheetViews>"
        s += "<sheetFormatPr defaultRowHeight=\"15\"/>"
        if !sheet.columns.isEmpty {
            s += "<cols>"
            for (i, column) in sheet.columns.enumerated() {
                s += "<col min=\"\(i + 1)\" max=\"\(i + 1)\" width=\"\(column.width)\" customWidth=\"1\"/>"
            }
            s += "</cols>"
        }
        s += "<sheetData>"
        s += "<row r=\"1\">"
        for (i, column) in sheet.columns.enumerated() {
            s += inlineString(ref: "\(columnName(i))1", column.title, style: 1)
        }
        s += "</row>"
        for (r, row) in sheet.rows.enumerated() {
            let rowNumber = r + 2
            s += "<row r=\"\(rowNumber)\">"
            for (c, cell) in row.enumerated() {
                let ref = "\(columnName(c))\(rowNumber)"
                switch cell {
                case .text(let text):
                    if !text.isEmpty { s += inlineString(ref: ref, text, style: 0) }
                case .number(let value):
                    guard value.isFinite else { continue }
                    let style = value == value.rounded() ? 0 : 4
                    s += "<c r=\"\(ref)\"\(style == 0 ? "" : " s=\"\(style)\"")><v>\(number(value))</v></c>"
                case .date(let date):
                    s += "<c r=\"\(ref)\" s=\"2\"><v>\(number(excelSerial(date)))</v></c>"
                case .link(let url):
                    guard !url.isEmpty else { continue }
                    // Formula + cached text: clickable in Excel/Numbers/Sheets, readable everywhere.
                    let formula = "HYPERLINK(\"\(url.replacingOccurrences(of: "\"", with: "\"\""))\")"
                    s += "<c r=\"\(ref)\" s=\"3\" t=\"str\"><f>\(escape(formula))</f><v>\(escape(url))</v></c>"
                case .empty:
                    continue
                }
            }
            s += "</row>"
        }
        s += "</sheetData>"
        if !sheet.columns.isEmpty { s += "<autoFilter ref=\"A1:\(last)\(lastRow)\"/>" }
        return s + "</worksheet>"
    }

    private static func inlineString(ref: String, _ text: String, style: Int) -> String {
        let clipped = text.count > 32_000 ? String(text.prefix(32_000)) : text   // Excel's cell limit is 32,767
        return "<c r=\"\(ref)\" t=\"inlineStr\"\(style == 0 ? "" : " s=\"\(style)\"")><is><t xml:space=\"preserve\">\(escape(clipped))</t></is></c>"
    }

    // MARK: Helpers

    /// A, B, … Z, AA, AB, …
    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    /// Excel's date number (days since 1899-12-30), in the phone's time zone.
    static func excelSerial(_ date: Date) -> Double {
        let local = date.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: date))
        return local / 86_400 + 25_569
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(format: "%.10g", value)
    }

    /// XML-safe text: escapes markup and drops characters XML doesn't allow.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                let v = scalar.value
                let allowed = v == 0x9 || v == 0xA || v == 0xD || (0x20...0xD7FF).contains(v)
                    || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
                if allowed { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Sheet names: at most 31 characters, none of : \ / ? * [ ], not blank, no duplicates.
    private static func uniqueNames(_ sheets: [Sheet]) -> [Sheet] {
        var used: Set<String> = []
        return sheets.map { sheet in
            var base = String(sheet.name.filter { !":\\/?*[]".contains($0) }
                .trimmingCharacters(in: CharacterSet(charactersIn: "' ")).prefix(31))
            if base.isEmpty { base = "Sheet" }
            var name = base
            var n = 2
            while used.contains(name.lowercased()) {
                let suffix = " (\(n))"
                name = String(base.prefix(31 - suffix.count)) + suffix
                n += 1
            }
            used.insert(name.lowercased())
            return Sheet(name: name, columns: sheet.columns, rows: sheet.rows)
        }
    }
}

/// Minimal ZIP writer (files stored uncompressed). Spreadsheets of a few thousand rows stay
/// small, and skipping compression keeps it simple and quick on the phone.
enum Zip {
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        let (time, date) = dosTimestamp(Date())
        for (name, data) in files {
            let nameBytes = Data(name.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            // Local file header
            out.append(le32: 0x04034b50)
            out.append(le16: 20)          // version needed
            out.append(le16: 0x0800)      // UTF-8 names
            out.append(le16: 0)           // stored
            out.append(le16: time)
            out.append(le16: date)
            out.append(le32: crc)
            out.append(le32: UInt32(data.count))
            out.append(le32: UInt32(data.count))
            out.append(le16: UInt16(nameBytes.count))
            out.append(le16: 0)
            out.append(nameBytes)
            out.append(data)
            // Central directory entry
            central.append(le32: 0x02014b50)
            central.append(le16: 20)      // made by
            central.append(le16: 20)      // needed
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: time)
            central.append(le16: date)
            central.append(le32: crc)
            central.append(le32: UInt32(data.count))
            central.append(le32: UInt32(data.count))
            central.append(le16: UInt16(nameBytes.count))
            central.append(le16: 0)       // extra
            central.append(le16: 0)       // comment
            central.append(le16: 0)       // disk
            central.append(le16: 0)       // internal attributes
            central.append(le32: 0)       // external attributes
            central.append(le32: offset)
            central.append(nameBytes)
        }
        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.append(le32: 0x06054b50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(files.count))
        out.append(le16: UInt16(files.count))
        out.append(le32: UInt32(central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    private static func dosTimestamp(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let year = max((c.year ?? 1980) - 1980, 0)
        let day = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
