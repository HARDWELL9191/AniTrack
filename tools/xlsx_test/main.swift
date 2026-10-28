// CI check for AniTrack/Services/XLSXWriter.swift: builds a sample workbook with tricky
// content; tools/xlsx_test/verify.py then opens it with openpyxl and checks every cell.
import Foundation

let date = Date(timeIntervalSince1970: 1_761_609_600)   // 2025-10-28 00:00 UTC
var rows: [[XLSXWriter.Cell]] = [
    [.text("Frieren: Beyond Journey's End"), .text("Sousou no Frieren"), .number(10), .number(28), .number(28),
     .date(date), .link("https://anilist.co/anime/154587")],
    [.text("Tom & Jerry <\"quoted\"> 'x'"), .text("Čšž đ — 日本語 🎉"), .number(8.5), .number(3), .empty,
     .empty, .link("https://example.com/?a=\"b\"&c=1")],
    [.text("  spaced  "), .text("bad\u{0001}char\u{000B}s"), .number(0.1), .number(-2), .number(1234567),
     .date(date.addingTimeInterval(86_400 * 365)), .link("")],
    [.text(String(repeating: "x", count: 40_000)), .empty, .empty, .empty, .empty, .empty, .empty]
]
for i in 0..<1_000 {
    rows.append([.text("Show \(i)"), .text(""), .number(Double(i % 10)), .number(Double(i)), .number(12),
                 .date(date), .link("https://anilist.co/anime/\(i)")])
}
let columns = ["Title", "Other", "Score", "Progress", "Episodes", "Added", "AniList"].map { XLSXWriter.Column(title: $0, width: 20) }
let sheets = [
    XLSXWriter.Sheet(name: "Watching", columns: columns, rows: rows),
    XLSXWriter.Sheet(name: "Bad:/Name?*[x]", columns: columns, rows: []),
    XLSXWriter.Sheet(name: "watching", columns: columns, rows: [rows[0]]),
    XLSXWriter.Sheet(name: String(repeating: "L", count: 40), columns: columns, rows: [rows[1]])
]
let data = XLSXWriter.data(sheets: sheets)
try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote \(data.count) bytes; serial \(XLSXWriter.excelSerial(date)); col 27 = \(XLSXWriter.columnName(26)), col 703 = \(XLSXWriter.columnName(702))")
precondition(XLSXWriter.columnName(0) == "A" && XLSXWriter.columnName(25) == "Z")
precondition(XLSXWriter.columnName(26) == "AA" && XLSXWriter.columnName(702) == "AAA")
precondition(CRC32.checksum(Data("123456789".utf8)) == 0xCBF43926)
