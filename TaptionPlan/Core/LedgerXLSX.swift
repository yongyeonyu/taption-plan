import Foundation

/// 작은 엑셀(.xlsx) 쓰개(LED1111A05). 바깥 라이브러리 없이 시트 하나·서식 몇 개·수식만 쓴다.
/// 압축하지 않은 zip(STORE)에 OOXML 파일을 담는다. 엑셀·넘버스·구글 시트가 모두 연다.
struct LedgerXLSX {
    enum Style: Int {
        case plain = 0, title = 1, header = 2, money = 3, moneyBold = 4, bold = 5, note = 6
    }

    enum Value {
        case text(String)
        case number(Double)
        /// 수식과 미리 계산한 값. 값이 있어야 미리보기·파일 앱처럼 계산하지 않는 곳에서도 숫자가 보인다.
        case formula(String, cached: Double? = nil)
        case empty
    }

    struct Cell {
        var value: Value
        var style: Style = .plain
    }

    var sheetName: String
    var rows: [[Cell]] = []
    /// 열 너비(글자 수).
    var widths: [Double] = []

    mutating func add(_ cells: [Cell]) { rows.append(cells) }

    func data() -> Data {
        var zip = StoreZip()
        zip.add("[Content_Types].xml", Self.contentTypes)
        zip.add("_rels/.rels", Self.rootRels)
        zip.add("xl/workbook.xml", workbook)
        zip.add("xl/_rels/workbook.xml.rels", Self.workbookRels)
        zip.add("xl/styles.xml", Self.styles)
        zip.add("xl/worksheets/sheet1.xml", sheet)
        return zip.finish()
    }

    /// 엑셀 시트 이름 규칙: [ ] : * ? / \ 를 쓸 수 없고, 작은따옴표로 시작·끝날 수 없으며 31자까지(리뷰).
    static func safeSheetName(_ name: String) -> String {
        var clean = String(name.map { "[]:*?/\\".contains($0) ? "-" : $0 })
        while clean.hasPrefix("'") { clean.removeFirst() }
        while clean.hasSuffix("'") { clean.removeLast() }
        clean = String(clean.prefix(31)).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Sheet1" : clean
    }

    static func column(_ index: Int) -> String {
        var n = index + 1, name = ""
        while n > 0 { let r = (n - 1) % 26; name = String(UnicodeScalar(65 + r)!) + name; n = (n - 1) / 26 }
        return name
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0에 못 쓰는 제어 문자는 뺀다.
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    private var sheet: String {
        var xml = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        if !widths.isEmpty {
            xml += "<cols>" + widths.enumerated().map { #"<col min="\#($0.offset + 1)" max="\#($0.offset + 1)" width="\#($0.element)" customWidth="1"/>"# }.joined() + "</cols>"
        }
        xml += "<sheetData>"
        for (r, row) in rows.enumerated() {
            xml += #"<row r="\#(r + 1)">"#
            for (c, cell) in row.enumerated() {
                let ref = Self.column(c) + String(r + 1)
                let s = cell.style.rawValue
                switch cell.value {
                case .empty: if s != 0 { xml += #"<c r="\#(ref)" s="\#(s)"/>"# }
                case let .text(text): xml += #"<c r="\#(ref)" s="\#(s)" t="inlineStr"><is><t xml:space="preserve">\#(Self.escape(text))</t></is></c>"#
                case let .number(value): xml += #"<c r="\#(ref)" s="\#(s)"><v>\#(value.isFinite ? String(value) : "0")</v></c>"#
                case let .formula(formula, cached):
                    let value = cached.flatMap { $0.isFinite ? "<v>\(String($0))</v>" : nil } ?? ""
                    xml += #"<c r="\#(ref)" s="\#(s)"><f>\#(Self.escape(formula))</f>\#(value)</c>"#
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    private var workbook: String {
        #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\#(Self.escape(Self.safeSheetName(sheetName)))" sheetId="1" r:id="rId1"/></sheets><calcPr fullCalcOnLoad="1"/></workbook>"#
    }

    private static let contentTypes = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>"#
    private static let rootRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
    private static let workbookRels = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#
    /// 0 보통, 1 제목(굵게·크게), 2 머리줄(굵게·연한 배경·테두리), 3 금액(#,##0), 4 굵은 금액, 5 굵게, 6 회색 작은 글.
    private static let styles = ##"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0;[Red]-#,##0"/></numFmts><fonts count="4"><font><sz val="11"/><name val="Apple SD Gothic Neo"/></font><font><b/><sz val="16"/><name val="Apple SD Gothic Neo"/></font><font><b/><sz val="11"/><name val="Apple SD Gothic Neo"/></font><font><sz val="10"/><color rgb="FF808080"/><name val="Apple SD Gothic Neo"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFF3E9D7"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left/><right/><top/><bottom style="thin"><color rgb="FF999999"/></bottom><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="7"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/><xf numFmtId="164" fontId="2" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyFont="1" applyBorder="1"/><xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="3" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs></styleSheet>"##
}

/// 압축하지 않는 zip. 파일마다 CRC-32만 계산한다.
struct StoreZip {
    private var body = Data()
    private var directory = Data()
    private var count: UInt16 = 0

    mutating func add(_ name: String, _ text: String) {
        let content = Data(text.utf8), nameData = Data(name.utf8)
        let crc = Self.crc32(content), offset = UInt32(body.count)
        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(0); local.le16(0); local.le16(0x21)
        local.le32(crc); local.le32(UInt32(content.count)); local.le32(UInt32(content.count)); local.le16(UInt16(nameData.count)); local.le16(0)
        body.append(local); body.append(nameData); body.append(content)
        var central = Data()
        central.le32(0x02014b50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0); central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(content.count)); central.le32(UInt32(content.count)); central.le16(UInt16(nameData.count))
        central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(offset)
        directory.append(central); directory.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var out = body
        out.append(directory)
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(UInt32(directory.count)); end.le32(UInt32(body.count)); end.le16(0)
        out.append(end)
        return out
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(shift)) & 0xFF)) } }
}
