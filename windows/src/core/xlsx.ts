// Writes a real Excel workbook (.xlsx): a few XML files in a ZIP (port of XLSXWriter.swift).
// One sheet per list, bold frozen header with filters, real numbers and dates, links.

export type Cell =
  | { kind: "text"; value: string }
  | { kind: "number"; value: number }
  | { kind: "date"; value: Date }
  | { kind: "link"; value: string }
  | { kind: "empty" };

export const text = (value: string): Cell => ({ kind: "text", value });
export const num = (value: number | null | undefined): Cell => (value == null || !Number.isFinite(value) ? { kind: "empty" } : { kind: "number", value });
export const date = (unix?: number | null): Cell => (unix && unix > 0 ? { kind: "date", value: new Date(unix * 1000) } : { kind: "empty" });
export const link = (value: string): Cell => ({ kind: "link", value });
export const empty: Cell = { kind: "empty" };

export interface Column { title: string; width: number }
export interface Sheet { name: string; columns: Column[]; rows: Cell[][] }

const MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
const REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const HEADER = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

export function escapeXML(s: string): string {
  let out = "";
  for (const ch of s) {
    switch (ch) {
      case "&": out += "&amp;"; break;
      case "<": out += "&lt;"; break;
      case ">": out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      case "'": out += "&apos;"; break;
      default: {
        const v = ch.codePointAt(0)!;
        const ok = v === 0x9 || v === 0xa || v === 0xd || (v >= 0x20 && v <= 0xd7ff) || (v >= 0xe000 && v <= 0xfffd) || (v >= 0x10000 && v <= 0x10ffff);
        if (ok) out += ch;
      }
    }
  }
  return out;
}

export function columnName(index: number): string {
  let n = index + 1;
  let name = "";
  while (n > 0) {
    const r = (n - 1) % 26;
    name = String.fromCharCode(65 + r) + name;
    n = Math.floor((n - 1) / 26);
  }
  return name;
}

/** Excel's date number (days since 1899-12-30), in local time. */
export function excelSerial(d: Date): number {
  const local = d.getTime() / 1000 - d.getTimezoneOffset() * 60;
  return local / 86_400 + 25_569;
}

function numberText(v: number): string {
  if (v === Math.round(v) && Math.abs(v) < 1e15) return String(Math.round(v));
  return String(Number(v.toPrecision(10)));
}

function contentTypes(count: number) {
  let s = HEADER + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">';
  s += '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>';
  s += '<Default Extension="xml" ContentType="application/xml"/>';
  s += '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>';
  s += '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>';
  for (let i = 0; i < count; i++) {
    s += `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`;
  }
  return s + "</Types>";
}

const ROOT_RELS = HEADER + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
  + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
  + "</Relationships>";

function workbook(sheets: Sheet[]) {
  let s = HEADER + `<workbook xmlns="${MAIN_NS}" xmlns:r="${REL_NS}"><bookViews><workbookView/></bookViews><sheets>`;
  sheets.forEach((sh, i) => { s += `<sheet name="${escapeXML(sh.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`; });
  s += "</sheets><definedNames>";
  sheets.forEach((sh, i) => {
    if (!sh.columns.length) return;
    const quoted = "'" + sh.name.replace(/'/g, "''") + "'";
    const last = columnName(sh.columns.length - 1);
    s += `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">` + escapeXML(`${quoted}!$A$1:$${last}$${sh.rows.length + 1}`) + "</definedName>";
  });
  return s + "</definedNames></workbook>";
}

function workbookRels(count: number) {
  let s = HEADER + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">';
  for (let i = 0; i < count; i++) s += `<Relationship Id="rId${i + 1}" Type="${REL_NS}/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`;
  s += `<Relationship Id="rId${count + 1}" Type="${REL_NS}/styles" Target="styles.xml"/>`;
  return s + "</Relationships>";
}

/** Styles: 0 normal, 1 bold header, 2 date, 3 link, 4 number with one decimal. */
const STYLES = HEADER + `<styleSheet xmlns="${MAIN_NS}">`
  + '<numFmts count="1"><numFmt numFmtId="164" formatCode="0.0"/></numFmts>'
  + '<fonts count="3"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
  + '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font>'
  + '<font><u/><sz val="11"/><color rgb="FF0563C1"/><name val="Calibri"/><family val="2"/></font></fonts>'
  + '<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>'
  + '<fill><patternFill patternType="solid"><fgColor rgb="FFF2E6EE"/><bgColor indexed="64"/></patternFill></fill></fills>'
  + '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
  + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
  + '<cellXfs count="5"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
  + '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>'
  + '<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>'
  + '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>'
  + '<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs>'
  + '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>';

function inlineString(ref: string, t: string, style: number) {
  const clipped = [...t].length > 32_000 ? [...t].slice(0, 32_000).join("") : t;
  return `<c r="${ref}" t="inlineStr"${style ? ` s="${style}"` : ""}><is><t xml:space="preserve">${escapeXML(clipped)}</t></is></c>`;
}

function worksheet(sh: Sheet) {
  const last = columnName(Math.max(sh.columns.length, 1) - 1);
  const lastRow = sh.rows.length + 1;
  const parts: string[] = [HEADER + `<worksheet xmlns="${MAIN_NS}" xmlns:r="${REL_NS}">`];
  parts.push(`<dimension ref="A1:${last}${lastRow}"/>`);
  parts.push('<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>'
    + '<selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>');
  parts.push('<sheetFormatPr defaultRowHeight="15"/>');
  if (sh.columns.length) {
    parts.push("<cols>" + sh.columns.map((c, i) => `<col min="${i + 1}" max="${i + 1}" width="${c.width}" customWidth="1"/>`).join("") + "</cols>");
  }
  parts.push("<sheetData><row r=\"1\">" + sh.columns.map((c, i) => inlineString(`${columnName(i)}1`, c.title, 1)).join("") + "</row>");
  sh.rows.forEach((row, r) => {
    const n = r + 2;
    let s = `<row r="${n}">`;
    row.forEach((cell, c) => {
      const ref = `${columnName(c)}${n}`;
      switch (cell.kind) {
        case "text": if (cell.value) s += inlineString(ref, cell.value, 0); break;
        case "number": {
          if (!Number.isFinite(cell.value)) break;
          const style = cell.value === Math.round(cell.value) ? 0 : 4;
          s += `<c r="${ref}"${style ? ` s="${style}"` : ""}><v>${numberText(cell.value)}</v></c>`;
          break;
        }
        case "date": s += `<c r="${ref}" s="2"><v>${numberText(excelSerial(cell.value))}</v></c>`; break;
        case "link": {
          if (!cell.value) break;
          const formula = `HYPERLINK("${cell.value.replace(/"/g, '""')}")`;
          s += `<c r="${ref}" s="3" t="str"><f>${escapeXML(formula)}</f><v>${escapeXML(cell.value)}</v></c>`;
          break;
        }
        case "empty": break;
      }
    });
    parts.push(s + "</row>");
  });
  parts.push("</sheetData>");
  if (sh.columns.length) parts.push(`<autoFilter ref="A1:${last}${lastRow}"/>`);
  parts.push("</worksheet>");
  return parts.join("");
}

function uniqueNames(sheets: Sheet[]): Sheet[] {
  const used = new Set<string>();
  return sheets.map((sh) => {
    let base = [...sh.name.replace(/[:\\/?*[\]]/g, "").replace(/^[' ]+|[' ]+$/g, "")].slice(0, 31).join("");
    if (!base) base = "Sheet";
    let name = base;
    let n = 2;
    while (used.has(name.toLowerCase())) {
      const suffix = ` (${n})`;
      name = [...base].slice(0, 31 - suffix.length).join("") + suffix;
      n++;
    }
    used.add(name.toLowerCase());
    return { ...sh, name };
  });
}

export function xlsx(sheetsIn: Sheet[]): Uint8Array {
  const sheets = uniqueNames(sheetsIn);
  const enc = new TextEncoder();
  const files: [string, Uint8Array][] = [
    ["[Content_Types].xml", enc.encode(contentTypes(sheets.length))],
    ["_rels/.rels", enc.encode(ROOT_RELS)],
    ["xl/workbook.xml", enc.encode(workbook(sheets))],
    ["xl/_rels/workbook.xml.rels", enc.encode(workbookRels(sheets.length))],
    ["xl/styles.xml", enc.encode(STYLES)],
  ];
  sheets.forEach((sh, i) => files.push([`xl/worksheets/sheet${i + 1}.xml`, enc.encode(worksheet(sh))]));
  return zip(files);
}

// MARK: ZIP (stored, no compression)

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

export function crc32(data: Uint8Array): number {
  let crc = 0xffffffff;
  for (let i = 0; i < data.length; i++) crc = CRC_TABLE[(crc ^ data[i]) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function zip(files: [string, Uint8Array][]): Uint8Array {
  const now = new Date();
  const time = (now.getHours() << 11) | (now.getMinutes() << 5) | Math.floor(now.getSeconds() / 2);
  const day = (Math.max(now.getFullYear() - 1980, 0) << 9) | ((now.getMonth() + 1) << 5) | now.getDate();
  const enc = new TextEncoder();
  const chunks: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  const header = (size: number) => { const b = new Uint8Array(size); return { b, v: new DataView(b.buffer) }; };
  for (const [name, data] of files) {
    const nameBytes = enc.encode(name);
    const crc = crc32(data);
    const local = header(30);
    local.v.setUint32(0, 0x04034b50, true);
    local.v.setUint16(4, 20, true);
    local.v.setUint16(6, 0x0800, true);
    local.v.setUint16(8, 0, true);
    local.v.setUint16(10, time, true);
    local.v.setUint16(12, day, true);
    local.v.setUint32(14, crc, true);
    local.v.setUint32(18, data.length, true);
    local.v.setUint32(22, data.length, true);
    local.v.setUint16(26, nameBytes.length, true);
    local.v.setUint16(28, 0, true);
    chunks.push(local.b, nameBytes, data);
    const c = header(46);
    c.v.setUint32(0, 0x02014b50, true);
    c.v.setUint16(4, 20, true);
    c.v.setUint16(6, 20, true);
    c.v.setUint16(8, 0x0800, true);
    c.v.setUint16(10, 0, true);
    c.v.setUint16(12, time, true);
    c.v.setUint16(14, day, true);
    c.v.setUint32(16, crc, true);
    c.v.setUint32(20, data.length, true);
    c.v.setUint32(24, data.length, true);
    c.v.setUint16(28, nameBytes.length, true);
    c.v.setUint32(42, offset, true);
    central.push(c.b, nameBytes);
    offset += 30 + nameBytes.length + data.length;
  }
  const centralSize = central.reduce((a, b) => a + b.length, 0);
  const end = header(22);
  end.v.setUint32(0, 0x06054b50, true);
  end.v.setUint16(8, files.length, true);
  end.v.setUint16(10, files.length, true);
  end.v.setUint32(12, centralSize, true);
  end.v.setUint32(16, offset, true);
  const all = [...chunks, ...central, end.b];
  const out = new Uint8Array(all.reduce((a, b) => a + b.length, 0));
  let p = 0;
  for (const part of all) { out.set(part, p); p += part.length; }
  return out;
}
