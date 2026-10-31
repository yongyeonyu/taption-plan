import Foundation
import XCTest
import TaptionPlanStore

/// 백업 형식 보조(월 키·JSON 줄·키 유도). 엔진·저장소 없이 형식만 확인한다.
/// (TaptionPlanTests/TaptionBackupV2Tests에서 옮겨 왔다.)
final class TaptionBackupFormatTests: XCTestCase {

    func testMonthKeysAndFileNames() {
        let month = TaptionBackupMonth(year: 2026, month: 10)
        XCTAssertEqual(month.fileName, "2026-10.taptionbackup")
        XCTAssertEqual(TaptionBackupMonth(fileName: "2026-10.taptionbackup"), month)
        XCTAssertNil(TaptionBackupMonth(fileName: "2026-13.taptionbackup"))
        XCTAssertNil(TaptionBackupMonth(fileName: "2026-10.zip"))
        XCTAssertEqual(month.adding(months: 3), TaptionBackupMonth(year: 2027, month: 1))
        XCTAssertEqual(month.adding(months: -10), TaptionBackupMonth(year: 2025, month: 12))
        XCTAssertTrue(TaptionBackupMonth(year: 2026, month: 9) < month)
    }

    func testJSONLineRoundTripsStringsAndDoublesExactly() throws {
        var generator = SystemRandomNumberGenerator()
        var doubles: [Double] = [0, -0.0, 1, 0.1, 1e-9, 1.7e18, 37.566_535_123_456_78, .leastNonzeroMagnitude, .greatestFiniteMagnitude]
        for _ in 0..<2_000 { doubles.append(Double.random(in: -200...200, using: &generator)) }
        for _ in 0..<2_000 { doubles.append(Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &generator))) }
        let text = "a\"b\\c\nd\re\tf\u{0001}g\u{1F600}한글 \u{2028}"
        var builder = TaptionBackupJSONLine.Builder()
        builder.string(text)
        builder.null()
        builder.int(Int64.min)
        for value in doubles where value.isFinite { try builder.double(value) }
        let line = builder.finish()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "줄 안에 날 줄바꿈이 없어야 한다")
        let fields = try TaptionBackupJSONLine.parse(line.dropLast())
        XCTAssertEqual(fields[0].string, text)
        XCTAssertTrue(fields[1].isNull)
        XCTAssertEqual(fields[2].int64, Int64.min)
        let finite = doubles.filter(\.isFinite)
        for (offset, value) in finite.enumerated() {
            XCTAssertEqual(fields[3 + offset].double?.bitPattern, value.bitPattern, "\(value)")
        }
    }

    func testPBKDF2MatchesPublishedVectorAndRejectsEmptyPassword() throws {
        // PBKDF2-HMAC-SHA256 공개 시험 벡터(4096회)의 앞 32바이트. 파이썬 hashlib.pbkdf2_hmac으로도 같은 값을 확인했다.
        let key = try TaptionBackupCrypto.deriveKey(
            password: "passwordPASSWORDpassword",
            salt: Data("saltSALTsaltSALTsaltSALTsaltSALTsalt".utf8), iterations: 4_096, minimumIterations: 1
        )
        XCTAssertEqual(
            TaptionBackupCrypto.hex(key.withUnsafeBytes { Array($0) }),
            "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1"
        )
        XCTAssertThrowsError(try TaptionBackupCrypto.deriveKey(password: "", salt: Data(repeating: 1, count: 16), iterations: 1, minimumIterations: 1))
        let first = try TaptionBackupCrypto.deriveKey(password: "123456", salt: Data(repeating: 1, count: 16), iterations: 10, minimumIterations: 1)
        let second = try TaptionBackupCrypto.deriveKey(password: "123456", salt: Data(repeating: 2, count: 16), iterations: 10, minimumIterations: 1)
        XCTAssertNotEqual(first.withUnsafeBytes { Data($0) }, second.withUnsafeBytes { Data($0) }, "솔트가 다르면 키가 달라야 한다")
    }
}
