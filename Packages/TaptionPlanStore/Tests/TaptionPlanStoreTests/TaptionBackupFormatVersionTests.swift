import CryptoKit
import Foundation
import XCTest
import TaptionPlanStore

/// 형식 버전 3(프레임 코덱·크기 봉인, Padmé 채움)과 버전 2 읽기 호환. 엔진·저장소 없이 형식만 확인한다.
final class TaptionBackupFormatVersionTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    // MARK: 버전 2 호환

    /// 변경 전 코드(TAPTBK02 작성기)가 만든 파일. 비밀번호 123456, 반복 100,000회, 청크 160바이트(프레임 여러 개).
    func testVersion2FixtureMadeByThePreviousWriterStillDecodesIdentically() async throws {
        let url = try write(try XCTUnwrap(Data(base64Encoded: Self.version2Fixture.joined())))
        let publicHeader = try TaptionBackupFileReader.readPublicHeader(at: url)
        XCTAssertEqual(publicHeader.version, 2)
        let (header, key) = try TaptionBackupFileReader.open(at: url, scopeKey: "2026-10", password: "123456")
        XCTAssertEqual(header.version, 2)
        XCTAssertGreaterThan(header.chunkCount, 2)
        try TaptionBackupFileReader.verifyBodyChecksum(at: url, header: header)
        let lines = try await decodedLines(url, header, key)
        XCTAssertEqual(lines, Self.lines)
        XCTAssertThrowsError(try TaptionBackupFileReader.open(at: url, scopeKey: "2026-10", password: "000000")) {
            XCTAssertEqual($0 as? TaptionBackupError, .wrongPassword)
        }
    }

    func testVersion2And3WritersProduceTheSameLines() async throws {
        for version in [2, 3] {
            let (url, written) = try makeFile(version: version)
            let (header, key) = try open(url)
            XCTAssertEqual(header, written)
            XCTAssertEqual(header.version, version)
            XCTAssertEqual(try Data(contentsOf: url).prefix(8), Data("TAPTBK0\(version)".utf8))
            let lines = try await decodedLines(url, header, key)
            XCTAssertEqual(lines, Self.lines, "버전 \(version)")
        }
    }

    // MARK: 버전 3 배치

    func testVersion3FramesExposeOnlyAPaddedSealedLength() throws {
        let (url, header) = try makeFile(version: 3)
        let data = try Data(contentsOf: url)
        let ranges = frameRanges(data)
        for range in ranges {
            let inner = range.count - 4 - TaptionBackupLayout.aeadOverhead
            XCTAssertEqual(inner, TaptionBackupLayout.paddedFrameLength(inner), "봉인 평문 길이는 Padmé 값이다")
        }
        XCTAssertEqual(ranges.last?.upperBound, data.count)
        XCTAssertEqual(ranges.count, header.chunkCount)
        XCTAssertGreaterThan(ranges.count, 2)
    }

    func testPaddedFrameLengthBoundsOverheadAndCollapsesSizes() {
        var buckets = Set<Int>()
        for length in 1...(1 << 16) {
            let padded = TaptionBackupLayout.paddedFrameLength(length)
            XCTAssertGreaterThanOrEqual(padded, length)
            XCTAssertLessThanOrEqual(Double(padded - length), Double(length) * 0.117 + 1, "\(length)")
            XCTAssertEqual(TaptionBackupLayout.paddedFrameLength(padded), padded)
            if length >= 1 << 15 { buckets.insert(padded) }
        }
        XCTAssertLessThanOrEqual(buckets.count, 32, "32KB~64KB 구간이 몇 개 값으로만 보인다")
        let length = (4 << 20) - 12_345
        XCTAssertLessThanOrEqual(TaptionBackupLayout.paddedFrameLength(length) - length, (4 << 20) / 32)
    }

    func testTamperedSwappedOrMovedVersion3FramesFail() async throws {
        let (url, header) = try makeFile(version: 3)
        let key = try open(url).key
        let original = try Data(contentsOf: url)
        let ranges = frameRanges(original)

        var flipped = original
        flipped[ranges[1].lowerBound + 20] ^= 0x01
        try flipped.write(to: url)
        await expectFailure(url, header, key, .authenticationFailed, "봉인 바이트 반전")

        var swapped = original.prefix(Int(TaptionBackupLayout.bodyOffset))
        var order = Array(ranges.indices)
        order.swapAt(0, 1)
        for index in order { swapped.append(original[ranges[index]]) }
        try swapped.write(to: url)
        await expectFailure(url, header, key, .authenticationFailed, "프레임 순서 교환")

        var lengthChanged = original
        lengthChanged[ranges[0].lowerBound + 3] ^= 0x01
        try lengthChanged.write(to: url)
        await expectFailure(url, header, key, nil, "봉인 길이 변조")

        var moved = header
        moved.month = "2026-09"
        try original.write(to: url)
        await expectFailure(url, moved, key, .authenticationFailed, "다른 달로 옮긴 프레임")
    }

    func testWrongPasswordFailsForVersion3() throws {
        let (url, _) = try makeFile(version: 3)
        XCTAssertThrowsError(
            try TaptionBackupFileReader.open(at: url, scopeKey: "2026-10", password: "000000", minimumIterations: 1)
        ) { XCTAssertEqual($0 as? TaptionBackupError, .wrongPassword) }
    }

    func testHeaderPlaintextHoldsOnlyFormatVersionAndKDFAndTheSealedBlockLengthIsFixed() throws {
        var sealedLengths = Set<Int>()
        for (timeZone, rows) in [("UTC", 1), ("America/Argentina/ComodRivadavia", 1_234_567)] {
            let (url, _) = try makeFile(version: 3, timeZone: timeZone, extraRows: rows)
            let prefix = try Data(contentsOf: url).prefix(TaptionBackupFileReader.headerPrefixBytes)
            let region = Data(prefix.dropFirst(12))
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: region) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["format", "version", "kdf", "sealed"])
            XCTAssertEqual(Set(try XCTUnwrap(object["kdf"] as? [String: Any]).keys), ["algorithm", "salt", "iterations"])
            XCTAssertEqual(object["version"] as? Int, 3)
            let text = String(decoding: region, as: UTF8.self)
            for forbidden in [timeZone, "rowCount", "chunk", "contentSHA256", "createdAt"] { XCTAssertFalse(text.contains(forbidden), forbidden) }
            sealedLengths.insert(try XCTUnwrap(object["sealed"] as? String).count)
        }
        XCTAssertEqual(sealedLengths.count, 1, "봉인된 헤더 블록 길이가 시간대·행 수와 무관하다")
    }

    func testMagicAndHeaderVersionMustAgree() throws {
        let (url, _) = try makeFile(version: 3)
        var data = try Data(contentsOf: url)
        data.replaceSubrange(0..<8, with: Data("TAPTBK02".utf8))
        XCTAssertThrowsError(try TaptionBackupFileReader.parsePublicHeader(data)) {
            XCTAssertEqual($0 as? TaptionBackupError, .unsupportedVersion(3))
        }
        data.replaceSubrange(0..<8, with: Data("TAPTBK01".utf8))
        XCTAssertThrowsError(try TaptionBackupFileReader.parsePublicHeader(data)) {
            XCTAssertEqual($0 as? TaptionBackupError, .notABackup)
        }
    }

    // MARK: 도우미

    private static let password = "482915"
    private static let salt = Data((0..<16).map { UInt8($0 * 5 + 1) })

    private static let lines: [String] = [
        ##"["#readings","id","ts","latitude","extra"]"##,
        ##"["r","00000000-0000-4000-8000-000000000001",1790000000.5,37.5665,null]"##,
        ##"["r","00000000-0000-4000-8000-000000000002",1790000007.5,37.56651,null]"##,
        ##"["r","00000000-0000-4000-8000-000000000003",1790000014.5,37.56652,"{\"wifi\":\"카페\"}"]"##,
        ##"["r","00000000-0000-4000-8000-000000000004",1790000021.5,37.56653,null]"##,
        ##"["r","00000000-0000-4000-8000-000000000005",1790000028.5,37.56654,null]"##,
        ##"["#records","id","kind","start","end","updated","origin","deleted","ord","body"]"##,
        ##"["c","c1","memo",1790000100.0,null,1790000200.0,"user",0,0,"{\"t\":\"한글 메모\"}"]"##,
        ##"["c","c2","plan",1790000150.0,1790000160.0,1790000190.0,"user",1,1,"{}"]"##,
        ##"["#raw","kind","id","ts","seq","origin","provenance","payload"]"##,
        ##"["w","watch.summary","w1",1790000300.25,1,"auto","[\"watch\"]","{\"steps\":12}"]"##,
    ]

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("taption-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func write(_ data: Data) throws -> URL {
        let url = try makeDirectory().appendingPathComponent("2026-10.taptionbackup")
        try data.write(to: url)
        return url
    }

    /// 고정 줄로 파일을 쓴다(`extraRows`는 헤더 숫자만 바꿔 봉인 길이가 자릿수를 드러내지 않는지 본다).
    private func makeFile(
        version: Int, timeZone: String = "Asia/Seoul", extraRows: Int = 0
    ) throws -> (URL, TaptionBackupHeader) {
        let url = try makeDirectory().appendingPathComponent("2026-10.taptionbackup")
        let key = try TaptionBackupCrypto.deriveKey(password: Self.password, salt: Self.salt, iterations: 1_000, minimumIterations: 1)
        let writer = try TaptionBackupFileWriter(
            url: url, month: "2026-10", key: key, salt: Self.salt, codec: .zlib, chunkBytes: 160, version: version
        )
        var hasher = SHA256()
        for line in Self.lines {
            let data = Data((line + "\n").utf8)
            hasher.update(data: data)
            try writer.append(data)
        }
        let digest = TaptionBackupCrypto.hex(hasher.finalize())
        try writer.append(Data("[\"#end\",5,2,1790000000.5,1790000300.25,\"\(digest)\",1790000200.0]\n".utf8))
        let template = TaptionBackupHeader(
            month: "2026-10", timeZone: timeZone, createdAt: 1_790_100_000.125 + Double(extraRows),
            kdf: .init(algorithm: "PBKDF2-HMAC-SHA256", salt: Self.salt.base64EncodedString(), iterations: 1_000),
            compression: "zlib", chunkBytes: 160, chunkCount: 0, plaintextBytes: 0,
            readingCount: 5, recordCount: 2, rowCount: 7 + extraRows,
            firstTimestamp: 1790000000.5, lastTimestamp: 1790000300.25, latestRecordUpdate: 1790000200.0,
            contentSHA256: digest, bodyBytes: 0, bodySHA256: ""
        )
        return (url, try writer.finish(header: template))
    }

    private func open(_ url: URL) throws -> (header: TaptionBackupHeader, key: SymmetricKey) {
        try TaptionBackupFileReader.open(at: url, scopeKey: "2026-10", password: Self.password, minimumIterations: 1)
    }

    private func decodedLines(_ url: URL, _ header: TaptionBackupHeader, _ key: SymmetricKey) async throws -> [String] {
        var lines: [String] = []
        try await TaptionBackupFileReader.decode(at: url, header: header, key: key) { lines.append(String(decoding: $0, as: UTF8.self)) }
        return lines
    }

    private func frameRanges(_ data: Data) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = Int(TaptionBackupLayout.bodyOffset)
        while offset + 4 <= data.count {
            let sealed = Int(TaptionBackupCrypto.readUInt32(data, at: offset))
            ranges.append(offset..<(offset + 4 + sealed))
            offset += 4 + sealed
        }
        return ranges
    }

    private func expectFailure(
        _ url: URL, _ header: TaptionBackupHeader, _ key: SymmetricKey, _ expected: TaptionBackupError?, _ label: String
    ) async {
        do {
            _ = try await decodedLines(url, header, key)
            XCTFail("\(label): 변조가 통과됨")
        } catch {
            XCTAssertTrue(error is TaptionBackupError, label)
            if let expected { XCTAssertEqual(error as? TaptionBackupError, expected, label) }
        }
    }

    private static let version2Fixture: [String] = [
        "VEFQVEJLMDIAAAgAeyJmb3JtYXQiOiJ0YXB0aW9uLWJhY2t1cCIsImtkZiI6eyJhbGdvcml0aG0iOiJQQktERjItSE1BQy1TSEEyNTYiLCJpdGVyYXRp",
        "b25zIjoxMDAwMDAsInNhbHQiOiJBd29SR0I4bUxUUTdRa2xRVjE1bGJBPT0ifSwic2VhbGVkIjoiQmIwUy9OV1hKZGplcEFIWTdpTFZuS084YlFwNGdF",
        "aGp2RUFQclpQRnBLSy9zTlprdTIwZHphK1ZCcmFNdXZma1p3WEZqQzlLWG40UGNzbE5Mc0FteWZZZ0xnSHdwK0N0WnZrM04yZ2VwTFg0b1VySmpnbU1o",
        "ZXFnemF2UVU0VXp0ZWdscFMycTM0OFp5V1hhVGVqLzltNGpOOGNGemJQSSsyYldJRE0yMlVxalhpclFHTzdsNTRDRWU3d1RXdUZTMkp2S0lGQ2Z2aHhU",
        "NlNOWUx2NDBNNmNUeHVPR0tCcTNTbHJTdURpeVp3RkdwTm80S3Q1R3kzZ1JOSUhnQ2ZvODB2djc2WWRWaFZEem5rQzNnYkkvNTNJdzl3enVPdW4yVEJQ",
        "cVZ1MHNqK3lKbHUzSXZZeExreUthOXBYaTlGQlBhNXhLcVNMU0JuMG9mS0MyR2NVVzAraTBxQ1E5RzRtOEFZUStqMVVNQjZSRTRjTTUxWitzT0hsRTlj",
        "Vm1OUHhrdEh2YitsSkdmVE80K1VXQXBZSHIzNG1SUzM0cVhLRFhKWUcvNlIvcGRPSUJyeTc5RmF2aGJsbk1Ebi9WaVowWFZEdGFUZDBEQVpFdDNUL0ZE",
        "VzdMVlVQZG9wNjlPNmtXMWtwREQrSjNua2V3Wnk0YTRYVE15ZHFhelZYYTB3czZjRmhic01YeEs1c1BSV29FOXRMdGxLQUZyZ0xMSkFEM0M0YVdEZCsv",
        "Y0oyVVlGZG9KOHhZY2hyemdLSktsTWJsYVM5Wnl5bHoyRDRnM3pWK3dmUGxLL1QwSnpxclNvZkRMUnJlWVRSUExSRFc2S2wxUmkvV3ZtK0pKNFZsT3Iv",
        "b1pUU0dIOEpnODV5SEdmZHliL2lJYW0xa1dJbnMyeCs1c21SdFB4d1hVbHgySGdpZitDeHVYbER1aFVNQXY1R1NuZXNVdGxFemxTa1QxVFAyeG5UNDAy",
        "UEZWZ0k2WWtjb08xVnJUMVBsZlNxN0FqM0p6QVF6aDErNXNLS1E4cUJ0UXhsK21Ra0tmdDlodUlEUkhGbHFvZWl2YjdpWklFRGlwTnFySFZ3eG90MTBi",
        "M0VOa1lVR1JYaHl5SWhQUWxtZm80RU9EZENTQmJUNG5lRlhuYVdmVWtJPSIsInZlcnNpb24iOjJ9ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICACAAAAcgAAAG1C/2YhScY+4diMYZd0zsusq4Bh",
        "FXzYEv3wdGkmL6IWmo5PF+gQb56mwl0CLUmbjYjOkbsRfdnlvsvf8qS7XOwTxgQSy+74N4MCQIhZj/Zg7XrvVjqk3KNEv51zByUcT1SuoYsYzr7/5GVt",
        "lsbyAgAAAEgAAABJb+0Stg8UH23X9LGwCxgkv7YpL3mkLVwR880JLbwFCFPC0w91Zo64ckwrPqkX2ln/PI+aUHM69ZhrDxnauMzk/7MRV9S2v3STWgIA",
        "AABbAAAAX+Hg3OegBBb0ePnyrZMCcrSdZb6BSnCk05hZPzfJToMMWW3lcc8lHNza7pKdE4f45IG6N3AWyRW07Eozl7QQxOHvrnoZZ2OLwOTfWugbKkE+",
        "tXZwZwVpx6r+G/vzw7MlAgAAAJAAAABYtR8PMwVlE0CQ8SUCFza3cA+5OZoUi638dqFRR4UrRbVhKoHgqmkXJWM22+Hoq1zK/ZuTaODmuN0Y80NAyN5X",
        "rJrW/uPTpsuRdH8U1Gj9uRVZy+5GVZz1sgIAAABRAAAAWtkXtgQ1zlQpedEcvOZcUmb2lCllgujBNK6dL76NK9+Zo5luQw+3IhATG7NV6BkDUQW0F/PE",
        "lQlcCuNt0+Sx+idb+xjX04Am8lXoisvMDFNXFLe3MvqR4iEjJQIAAABYAAAAaTlsmUqueWdII9JVI0i81+l6g09C/6VG8ny497CKUaXGUNCEpU6U2kdM",
        "GdAUz9GWpE70Ry0oY0Y/2arf+Tu2EZ8SD9IqthqnloR1DuuSzglRMuYy9akL0WeG5L/AXDjjYONJptCZuMXTbwIAAACJAAAAgbncXKGHvF9rAFfDfvlG",
        "n1CyARSZugzgJmFCbwrUVq5sEMN0zkJDYtwgN6XwUWRWm9XYIcQxfbrDyVJ810LtnCgM+1YLIPt6xS/uqvPUAk63H315YGrxnrf5do9eXwrqB8vqEE19",
        "IjmQVJXdePf09EqRDsAOP76EO8+JFxZ0zV9EDQIAAABRAAAAZX9LVfZrcd4PXi7c9L8R5nYOS1ZGZngevqVHZq8yN8mINgWNDpg4ZPMTY+nvoNExzhL+",
        "1EN0FztAXL6vOBMMmMhYNOxq44+gIvO7mC81W0sOPK31g6uDzn+jBvvmr0euDct+AFx6AgAAAHgAAAB2wym2r+FMHFHTj0njxjw4jf12pSa6udCBks3P",
        "wAD2FJ9M9sExhAfCn4FqisL3vyG98DhgwTGXbeVkdAPN5CBWaDMGNeTrELaOwLsa9LhX12Y+Uv2GST4AQ69Nj+H9Xs6WikGKfFc+pshtpsghyX9qkdWy",
        "pmWZAw==",
    ]
}
