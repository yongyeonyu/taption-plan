import XCTest
@testable import TaptionPlan

/// 값은 공용 함수로 합치기 전의 원본 함수로 뽑았다. 고치면 저장된 기록 ID가 깨진다.
final class StableRecordIDTests: XCTestCase {
    func testDualFNVKeepsStoredIDs() {
        let expected: [(String, String)] = [
            ("", "25232284-E49C-52CB-87CA-EB85B179379E"),
            ("a", "8CEC0186-4CDC-53AF-8A7B-936C2CAF28BC"),
            ("HKQuantityTypeIdentifierStepCount|2026-07-30", "855D9534-B76C-58E2-872C-26A9EC2E7115"),
            ("activity-fragment.00000000-0000-0000-0000-000000000001.1785369600000.1785373200000", "3B432071-DBC4-5CED-B16E-4C79E3F130D3"),
            ("걷기.지하철|집", "50BB987B-A5B1-59D6-8A46-5BF7A86AE9E9"),
        ]
        for (seed, id) in expected {
            XCTAssertEqual(StableRecordID.dualFNV(seed).uuidString, id, seed)
        }
    }

    func testGoldenMixedFNVKeepsStoredIDs() {
        let expected: [(String, String)] = [
            ("", "14792F74-12FF-5E9A-B464-67B4A659CF0E"),
            ("a", "0F22F515-1692-52A0-9F68-A2695B18874B"),
            ("HKQuantityTypeIdentifierStepCount|2026-07-30", "F4696F05-26AA-5698-94C9-3DAF46457846"),
            ("activity-fragment.00000000-0000-0000-0000-000000000001.1785369600000.1785373200000", "E6F64786-F338-543E-AE95-B6A5ED4C0574"),
            ("걷기.지하철|집", "EBA97CAB-7789-5527-8B28-CCFA152B3974"),
        ]
        for (seed, id) in expected {
            XCTAssertEqual(StableRecordID.goldenMixedFNV(seed).uuidString, id, seed)
        }
    }

    func testIndexMixedFNVKeepsStoredIDs() {
        let expected: [(String, String)] = [
            ("", "2C902C51-BFA7-567E-AC7E-1B17643786E7"),
            ("a", "97E6329E-3EB5-5F77-8731-B429B38A9BDA"),
            ("1|1785369600|1785373200", "DAB32650-53A5-5696-9270-C4EAE9678CFC"),
            ("걷기.지하철|집", "A3CFF01E-FD77-5741-83D0-1446C4079C0B"),
        ]
        for (seed, id) in expected {
            XCTAssertEqual(StableRecordID.indexMixedFNV(seed).uuidString, id, seed)
        }
    }

    func testFoldedFNVKeepsStoredIDs() {
        let expected: [(String, String)] = [
            ("", "00000000-0000-5000-8000-000000000000"),
            ("a", "86000000-0000-5000-8000-000000000000"),
            ("HKQuantityTypeIdentifierStepCount|2026-07-30", "7292CCCF-6030-58CA-9B1A-BBCEB6963524"),
            ("activity-fragment.00000000-0000-0000-0000-000000000001.1785369600000.1785373200000", "8E629665-8C2D-5978-8645-40A9392EA7EC"),
            ("걷기.지하철|집", "E3BA5A01-E02F-5431-AC26-E169DF309E22"),
        ]
        for (seed, id) in expected {
            XCTAssertEqual(StableRecordID.foldedFNV(seed).uuidString, id, seed)
        }
    }

    func testRemainderKeepsStoredIDs() {
        let source = UUID(uuidString: "12345678-9ABC-DEF0-1234-56789ABCDEF0")!
        let expected: [(Int, String)] = [
            (0, "86B5C3AD-F218-55F8-8D83-BD91E1AB1F21"),
            (1, "86B5B5E6-8F78-5182-8951-F5E2F8F1C74D"),
            (7, "86B5E66A-3BB6-5396-A082-823EE6EDFD0C"),
            (1000, "86C0EE0C-364E-52C7-9D59-BE716F39BCE3"),
        ]
        for (offset, id) in expected {
            XCTAssertEqual(StableRecordID.remainder(of: source, offset: offset).uuidString, id)
        }
    }
}
