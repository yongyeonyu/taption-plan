import CommonCrypto
import Compression
import CryptoKit
import Foundation

// 월 단위 백업 파일 형식(버전 1). 이전 백업 엔진과 호환하지 않는다.
//
// 파일 = 매직 "TAPTBK02"(8) + 헤더 영역 길이 u32 BE + 헤더 영역(평문 JSON, 공백으로 채움, 고정 2048바이트) + 프레임들
// 헤더 영역의 평문에는 형식 이름·버전·KDF(알고리즘·솔트·반복 횟수)와 봉인된 헤더 블록(`sealed`, base64)만 있다. 월은 파일 이름이다.
//   행 수·시각 범위·생성 시각·시간대·내용/본문 해시 같은 나머지 메타데이터는 같은 키로 AES-GCM 봉인한 헤더 블록 안에 있다
//   (AAD = 솔트·월·버전을 묶음). 평문 키 확인값은 없다: 헤더 블록의 GCM 태그가 맞아야 비밀번호가 맞다.
// 프레임 = 코덱 u8 + 압축 전 크기 u32 BE + 봉인 길이 u32 BE + 봉인(AES-GCM: nonce 12 + 암호문 + 태그 16)
// 프레임 평문 = JSON Lines(한 줄에 배열 하나). 표마다 스키마 줄(`["#readings",열...]`) 뒤에 행 줄이 온다.
//   센서 원본 행  ["r", id, ts, 열값..., extra]   기록 행  ["c", id, kind, start, end, updated, origin, deleted, ord, body]
//   마지막 줄(트레일러) ["#end", 센서 수, 기록 수, 첫 시각, 마지막 시각, 내용 SHA-256, 기록 최신 수정 시각]
//   기록 행의 deleted=1은 삭제 표시(톰스톤)다. 센서 원본에는 삭제 표시가 없다.
//   월 파일은 시작 시각이 그 달인 행을, 설정 파일(taption-settings.taptionbackup)은 시작 시각이 없는 기록을 담는다.
// 키 = PBKDF2-HMAC-SHA256(비밀번호, 헤더의 솔트, 헤더의 반복 횟수, 32바이트). 압축한 뒤 암호화한다.
// 각 프레임의 AAD가 솔트·월·프레임 번호·마지막 여부·코덱·크기를 묶어, 순서 바꿈·잘림·헤더 변조를 복호화 단계에서 잡는다.

enum TaptionBackupError: Error, Equatable {
    case emptyPassword
    case notABackup
    case unsupportedVersion(Int)
    case malformed(String)
    /// 비밀번호로 만든 키가 헤더의 키 확인값과 다르다.
    case wrongPassword
    /// 키는 맞지만 인증 태그가 맞지 않는다(파일이 바뀌었거나 깨졌다).
    case authenticationFailed
    case checksumMismatch
    case keyDerivationFailed
    case fileMissing(String)
    case destinationUnavailable(String)
    case verificationFailed(String)
    /// 쓰려는 비밀번호가 그 달 파일에 이미 쓰인 비밀번호와 다르다(`wrongPassword`는 복원·열기용). 오타나 변경으로
    /// 기존 파일과 읽을 수 없는 새 파일이 섞이는 것을 막는다. 연관값은 파일 이름.
    case passwordDiffersFromExistingBackup(String)
    /// iCloud 충돌 버전이 풀리지 않은 파일. 연관값은 파일 이름.
    case conflictingVersions(String)
}

/// 월(현지 달력 기준). 파일 이름은 `yyyy-MM.taptionbackup`.
struct TaptionBackupMonth: Hashable, Comparable, Sendable {
    static let fileExtension = "taptionbackup"

    var year: Int
    var month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 1)
    }

    init?(key: String) {
        let parts = key.split(separator: "-")
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        self.init(year: year, month: month)
    }

    init?(fileName: String) {
        let suffix = "." + Self.fileExtension
        guard fileName.hasSuffix(suffix) else { return nil }
        self.init(key: String(fileName.dropLast(suffix.count)))
    }

    var key: String { String(format: "%04d-%02d", year, month) }
    var fileName: String { key + "." + Self.fileExtension }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }

    func adding(months: Int) -> Self {
        let index = year * 12 + (month - 1) + months
        return Self(year: Int((Double(index) / 12).rounded(.down)), month: ((index % 12) + 12) % 12 + 1)
    }

    /// `[start, end)`. 시각은 이 달력의 시간대로 해석한다.
    func interval(calendar: Calendar) -> (start: Date, end: Date)? {
        guard let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let end = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return (start, end)
    }
}

/// 백업 파일 하나가 담는 범위: 한 달, 또는 달과 무관한 설정·분류 기록(시작 시각이 없는 기록).
enum TaptionBackupScope: Hashable, Sendable {
    static let settingsFileName = "taption-settings." + TaptionBackupMonth.fileExtension
    static let settingsKey = "settings"

    case month(TaptionBackupMonth)
    case settings

    init?(fileName: String) {
        if fileName == Self.settingsFileName {
            self = .settings
        } else if let month = TaptionBackupMonth(fileName: fileName) {
            self = .month(month)
        } else {
            return nil
        }
    }

    /// 헤더의 `month` 필드와 키 확인값·AAD에 쓰는 이름.
    var key: String {
        switch self {
        case .month(let month): month.key
        case .settings: Self.settingsKey
        }
    }

    var fileName: String {
        switch self {
        case .month(let month): month.fileName
        case .settings: Self.settingsFileName
        }
    }
}

/// 헤더 영역의 평문 부분. 비밀번호 없이 읽을 수 있는 것은 이것뿐이다.
struct TaptionBackupPublicHeader: Codable, Equatable, Sendable {
    var format: String
    var version: Int
    var kdf: TaptionBackupHeader.KDF
    /// 봉인된 헤더 블록(AES-GCM nonce + 암호문 + 태그)의 base64.
    var sealed: String
}

/// 복호화된 헤더(봉인된 헤더 블록의 내용 + 평문 부분). 파일 안에는 암호화돼 있다.
struct TaptionBackupHeader: Codable, Equatable, Sendable {
    struct KDF: Codable, Equatable, Sendable {
        var algorithm: String
        /// 16바이트 무작위 솔트(base64).
        var salt: String
        var iterations: Int
    }

    static let formatName = "taption-backup"
    static let currentVersion = 1

    var format = Self.formatName
    var version = Self.currentVersion
    var month: String
    var timeZone: String
    /// 이 파일을 만든 시각(초).
    var createdAt: Double
    var kdf: KDF
    var cipher = "AES-256-GCM"
    /// 프레임 압축에 선호한 코덱 이름(프레임마다 코덱 바이트가 따로 있다).
    var compression: String
    var chunkBytes: Int
    var chunkCount: Int
    var plaintextBytes: Int
    var readingCount: Int
    var recordCount: Int
    var rowCount: Int
    var firstTimestamp: Double?
    var lastTimestamp: Double?
    /// 기록 행(삭제 표시 포함)의 가장 늦은 수정 시각.
    var latestRecordUpdate: Double?
    /// 트레일러 앞 모든 줄의 SHA-256(hex). 같은 데이터면 같은 값이다.
    var contentSHA256: String
    var bodyBytes: Int
    /// 헤더 영역 뒤 모든 바이트의 SHA-256(hex).
    var bodySHA256: String
}

enum TaptionBackupCodec: UInt8, Sendable {
    case none = 0
    case lzfse = 1
    case zlib = 2

    var name: String {
        switch self {
        case .none: "none"
        case .lzfse: "lzfse"
        case .zlib: "zlib"
        }
    }

    fileprivate var algorithm: compression_algorithm? {
        switch self {
        case .none: nil
        case .lzfse: COMPRESSION_LZFSE
        case .zlib: COMPRESSION_ZLIB
        }
    }

    /// 압축이 이득일 때만 압축한 데이터와 코덱을, 아니면 원본과 `.none`을 돌려준다.
    func compress(_ data: Data) -> (codec: TaptionBackupCodec, data: Data) {
        guard let algorithm, !data.isEmpty else { return (.none, data) }
        let capacity = data.count + 4096
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm
                )
            }
        }
        guard size > 0, size < data.count else { return (.none, data) }
        output.removeSubrange(size...)
        return (self, output)
    }

    func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        guard let algorithm else {
            guard data.count == expectedSize else { throw TaptionBackupError.malformed("frame size") }
            return data
        }
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let size = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm
                )
            }
        }
        guard size == expectedSize else { throw TaptionBackupError.malformed("decompressed size") }
        return output
    }
}

enum TaptionBackupCrypto {
    static let defaultIterations = 600_000
    static let saltBytes = 16
    /// 헤더가 약한 반복 횟수로 파일을 만들거나(하한), 열 때 CPU를 오래 묶는(상한) 값을 막는다.
    static let minIterations = 100_000
    static let maxIterations = 5_000_000

    static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw TaptionBackupError.keyDerivationFailed }
        return data
    }

    /// PBKDF2-HMAC-SHA256(비밀번호 UTF-8, 솔트, 반복, 32바이트).
    /// `minimumIterations`는 테스트가 빠른 값을 쓰려고 낮출 때만 바꾼다(앱은 기본값 `minIterations`).
    static func deriveKey(
        password: String, salt: Data, iterations: Int, minimumIterations: Int = minIterations
    ) throws -> SymmetricKey {
        guard !password.isEmpty else { throw TaptionBackupError.emptyPassword }
        guard (max(1, minimumIterations)...maxIterations).contains(iterations), salt.count >= 8 else {
            throw TaptionBackupError.malformed("kdf parameters")
        }
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = passwordBytes.withUnsafeBufferPointer { passwordPointer in
            salt.withUnsafeBytes { saltPointer in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    UnsafeRawPointer(passwordPointer.baseAddress!).assumingMemoryBound(to: CChar.self),
                    passwordBytes.count,
                    saltPointer.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations), &derived, derived.count
                )
            }
        }
        guard status == kCCSuccess else { throw TaptionBackupError.keyDerivationFailed }
        return SymmetricKey(data: derived)
    }

    /// 헤더 블록의 AAD: 솔트·월·형식 버전을 묶어 다른 파일/월로 옮긴 블록을 거부한다.
    static func headerAAD(salt: Data, month: String, version: Int) -> Data {
        var aad = Data("TAPTBK02-HDR|".utf8)
        aad.append(salt)
        aad.append(Data("|\(month)|".utf8))
        aad.append(bigEndian(UInt32(version)))
        return aad
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func frameAAD(
        salt: Data, month: String, index: Int, isFinal: Bool, codec: TaptionBackupCodec, plainSize: Int
    ) -> Data {
        var aad = Data("TAPTBK02|".utf8)
        aad.append(salt)
        aad.append(Data("|\(month)|".utf8))
        aad.append(bigEndian(UInt32(index)))
        aad.append(isFinal ? 1 : 0)
        aad.append(codec.rawValue)
        aad.append(bigEndian(UInt32(plainSize)))
        return aad
    }

    static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.dropFirst(offset).prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

enum TaptionBackupLayout {
    static let magic = Data("TAPTBK02".utf8)
    static let headerRegionBytes = 2048
    static let bodyOffset = UInt64(magic.count + 4 + headerRegionBytes)
    /// 한 프레임 크기의 절대 상한(깨진 길이로 큰 메모리를 잡지 않게).
    static let maxFrameBytes = 256 << 20
    static let maxChunkBytes = 64 << 20
    static let aeadOverhead = 28

    /// 작성기는 줄을 모아 `chunkBytes`를 넘기기 전에 프레임을 닫으므로 프레임은 보통 `chunkBytes` 이하다.
    /// 줄 하나가 더 큰 경우를 위해 몇 배의 여유만 허용하고, 헤더의 `chunkBytes`를 믿어 큰 메모리를 잡지 않는다.
    static func maxPlainFrameBytes(chunkBytes: Int) -> Int {
        min(maxFrameBytes, max(chunkBytes * 4, 64 << 10))
    }
}

/// 임시 파일에 프레임을 차례로 쓰는 작성기. 줄을 모아 `chunkBytes`마다 압축·봉인한다.
final class TaptionBackupFileWriter {
    private let handle: FileHandle
    private let month: String
    private let key: SymmetricKey
    private let salt: Data
    private let codec: TaptionBackupCodec
    private let chunkBytes: Int
    private var pending = Data()
    private var frameIndex = 0
    private var bodyHasher = SHA256()
    private(set) var bodyBytes = 0
    private(set) var plaintextBytes = 0

    init(url: URL, month: String, key: SymmetricKey, salt: Data, codec: TaptionBackupCodec, chunkBytes: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw TaptionBackupError.destinationUnavailable("cannot create \(url.lastPathComponent)")
        }
        handle = try FileHandle(forWritingTo: url)
        self.month = month
        self.key = key
        self.salt = salt
        self.codec = codec
        self.chunkBytes = min(max(1, chunkBytes), TaptionBackupLayout.maxChunkBytes)
        try handle.write(contentsOf: TaptionBackupLayout.magic)
        try handle.write(contentsOf: TaptionBackupCrypto.bigEndian(UInt32(TaptionBackupLayout.headerRegionBytes)))
        try handle.write(contentsOf: Data(repeating: 0x20, count: TaptionBackupLayout.headerRegionBytes))
    }

    func append(_ line: Data) throws {
        if !pending.isEmpty, pending.count + line.count > chunkBytes {
            try flush(isFinal: false)
        }
        pending.append(line)
        plaintextBytes += line.count
    }

    var chunkCount: Int { frameIndex }

    /// 마지막 프레임을 쓰고 헤더를 채운 뒤 닫는다. 헤더에는 호출자가 채운 값에 쓰기 결과를 덧붙인다.
    func finish(header template: TaptionBackupHeader) throws -> TaptionBackupHeader {
        try flush(isFinal: true)
        var header = template
        header.chunkCount = frameIndex
        header.plaintextBytes = plaintextBytes
        header.bodyBytes = bodyBytes
        header.bodySHA256 = TaptionBackupCrypto.hex(bodyHasher.finalize())
        let json = try TaptionBackupHeaderCoding.encode(header, key: key, salt: salt)
        try handle.seek(toOffset: UInt64(TaptionBackupLayout.magic.count + 4))
        try handle.write(contentsOf: json)
        try handle.synchronize()
        try handle.close()
        return header
    }

    func abort() {
        try? handle.close()
    }

    private func flush(isFinal: Bool) throws {
        let plain = pending
        pending = Data()
        guard plain.count <= TaptionBackupLayout.maxPlainFrameBytes(chunkBytes: chunkBytes) else {
            throw TaptionBackupError.malformed("frame too large")
        }
        let compressed = codec.compress(plain)
        let aad = TaptionBackupCrypto.frameAAD(
            salt: salt, month: month, index: frameIndex, isFinal: isFinal,
            codec: compressed.codec, plainSize: plain.count
        )
        let sealed = try AES.GCM.seal(compressed.data, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw TaptionBackupError.malformed("seal") }
        var frame = Data([compressed.codec.rawValue])
        frame.append(TaptionBackupCrypto.bigEndian(UInt32(plain.count)))
        frame.append(TaptionBackupCrypto.bigEndian(UInt32(combined.count)))
        frame.append(combined)
        try handle.write(contentsOf: frame)
        bodyHasher.update(data: frame)
        bodyBytes += frame.count
        frameIndex += 1
    }
}

enum TaptionBackupHeaderCoding {
    /// 헤더를 봉인해 고정 크기 헤더 영역(평문 부분 + 봉인된 블록, 공백으로 채움)으로 만든다.
    static func encode(_ header: TaptionBackupHeader, key: SymmetricKey, salt: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let aad = TaptionBackupCrypto.headerAAD(salt: salt, month: header.month, version: header.version)
        let box = try AES.GCM.seal(try encoder.encode(header), using: key, authenticating: aad)
        guard let combined = box.combined else { throw TaptionBackupError.malformed("seal header") }
        let publicHeader = TaptionBackupPublicHeader(
            format: header.format, version: header.version, kdf: header.kdf, sealed: combined.base64EncodedString()
        )
        var json = try encoder.encode(publicHeader)
        guard json.count <= TaptionBackupLayout.headerRegionBytes else { throw TaptionBackupError.malformed("header too large") }
        json.append(Data(repeating: 0x20, count: TaptionBackupLayout.headerRegionBytes - json.count))
        return json
    }
}

/// 비밀번호 없이 헤더를 읽고, 비밀번호로 프레임을 풀어 줄을 넘겨 준다.
enum TaptionBackupFileReader {
    static var headerPrefixBytes: Int { TaptionBackupLayout.magic.count + 4 + TaptionBackupLayout.headerRegionBytes }

    /// 비밀번호 없이 읽는 평문 헤더 부분.
    static func readPublicHeader(at url: URL) throws -> TaptionBackupPublicHeader {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try parsePublicHeader(try handle.read(upToCount: headerPrefixBytes) ?? Data())
    }

    /// 파일 앞 `headerPrefixBytes`바이트(매직 + 길이 + 헤더 영역)에서 평문 헤더를 읽는다.
    static func parsePublicHeader(_ prefix: Data) throws -> TaptionBackupPublicHeader {
        let lengthEnd = TaptionBackupLayout.magic.count + 4
        guard prefix.count >= lengthEnd,
              prefix.prefix(TaptionBackupLayout.magic.count) == TaptionBackupLayout.magic else {
            throw TaptionBackupError.notABackup
        }
        let length = Int(TaptionBackupCrypto.readUInt32(prefix, at: TaptionBackupLayout.magic.count))
        guard length == TaptionBackupLayout.headerRegionBytes else { throw TaptionBackupError.malformed("header length") }
        guard prefix.count >= lengthEnd + length else { throw TaptionBackupError.malformed("header truncated") }
        let region = prefix.dropFirst(lengthEnd).prefix(length)
        guard let header = try? JSONDecoder().decode(TaptionBackupPublicHeader.self, from: Data(region)),
              header.format == TaptionBackupHeader.formatName else { throw TaptionBackupError.notABackup }
        guard header.version == TaptionBackupHeader.currentVersion else {
            throw TaptionBackupError.unsupportedVersion(header.version)
        }
        return header
    }

    /// 비밀번호로 키를 만들고 봉인된 헤더 블록을 연다. 블록의 GCM 태그가 맞지 않으면 `wrongPassword`
    /// (틀린 비밀번호와 헤더 손상을 구분할 수 없다). `scopeKey`는 파일 이름에서 온 월(또는 "settings")이다.
    /// 키 유도는 비싸므로 호출자가 같은 솔트·반복 횟수의 키를 캐시해 `key`로 넘길 수 있다.
    static func open(
        public publicHeader: TaptionBackupPublicHeader, scopeKey: String, password: String,
        minimumIterations: Int = TaptionBackupCrypto.minIterations, cachedKey: SymmetricKey? = nil
    ) throws -> (header: TaptionBackupHeader, key: SymmetricKey) {
        guard let salt = Data(base64Encoded: publicHeader.kdf.salt) else { throw TaptionBackupError.malformed("salt") }
        guard publicHeader.kdf.algorithm == "PBKDF2-HMAC-SHA256" else { throw TaptionBackupError.malformed("kdf") }
        let key = try cachedKey ?? TaptionBackupCrypto.deriveKey(
            password: password, salt: salt, iterations: publicHeader.kdf.iterations, minimumIterations: minimumIterations
        )
        guard let combined = Data(base64Encoded: publicHeader.sealed), combined.count > TaptionBackupLayout.aeadOverhead else {
            throw TaptionBackupError.malformed("sealed header")
        }
        let plain: Data
        do {
            plain = try AES.GCM.open(
                AES.GCM.SealedBox(combined: combined), using: key,
                authenticating: TaptionBackupCrypto.headerAAD(salt: salt, month: scopeKey, version: publicHeader.version)
            )
        } catch {
            throw TaptionBackupError.wrongPassword
        }
        guard let header = try? JSONDecoder().decode(TaptionBackupHeader.self, from: plain),
              header.month == scopeKey, header.kdf == publicHeader.kdf, header.version == publicHeader.version,
              header.format == publicHeader.format else {
            throw TaptionBackupError.malformed("header block does not match")
        }
        return (header, key)
    }

    static func open(
        at url: URL, scopeKey: String, password: String, minimumIterations: Int = TaptionBackupCrypto.minIterations
    ) throws -> (header: TaptionBackupHeader, key: SymmetricKey) {
        try open(
            public: try readPublicHeader(at: url), scopeKey: scopeKey, password: password,
            minimumIterations: minimumIterations
        )
    }

    /// 비밀번호 없이 본문 바이트 수와 SHA-256을 확인한다(전송 중 깨짐 등).
    static func verifyBodyChecksum(at url: URL, header: TaptionBackupHeader) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: TaptionBackupLayout.bodyOffset)
        var hasher = SHA256()
        var total = 0
        while let block = try handle.read(upToCount: 1 << 20), !block.isEmpty {
            hasher.update(data: block)
            total += block.count
        }
        guard total == header.bodyBytes, TaptionBackupCrypto.hex(hasher.finalize()) == header.bodySHA256 else {
            throw TaptionBackupError.checksumMismatch
        }
    }

    struct Counts: Equatable, Sendable {
        var readings = 0
        var records = 0
        var contentSHA256 = ""
    }

    /// 모든 프레임을 복호화·압축 해제해 줄마다 `handler`를 부른다(트레일러 제외). 끝에서 트레일러·헤더·내용 해시를
    /// 모두 대조한다. 하나라도 틀리면 던지므로, 반환될 때까지 `handler`가 받은 줄은 확정 전이다.
    @discardableResult
    static func decode(
        at url: URL, header: TaptionBackupHeader, key: SymmetricKey,
        isolation: isolated (any Actor)? = #isolation, handler: (Data) async throws -> Void
    ) async throws -> Counts {
        guard let salt = Data(base64Encoded: header.kdf.salt) else { throw TaptionBackupError.malformed("salt") }
        guard (1...TaptionBackupLayout.maxChunkBytes).contains(header.chunkBytes), header.chunkCount >= 0,
              header.chunkCount <= header.bodyBytes / (9 + TaptionBackupLayout.aeadOverhead) else {
            throw TaptionBackupError.malformed("header sizes")
        }
        let maxPlain = TaptionBackupLayout.maxPlainFrameBytes(chunkBytes: header.chunkBytes)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: TaptionBackupLayout.bodyOffset)
        var plainTotal = 0
        var counts = Counts()
        var hasher = SHA256()
        var trailer: [TaptionBackupJSONLine.Field]?
        var consumed = 0
        for index in 0..<header.chunkCount {
            let prefix = try handle.read(upToCount: 9) ?? Data()
            guard prefix.count == 9, let codec = TaptionBackupCodec(rawValue: prefix[prefix.startIndex]) else {
                throw TaptionBackupError.malformed("frame header")
            }
            let plainSize = Int(TaptionBackupCrypto.readUInt32(prefix, at: 1))
            let sealedSize = Int(TaptionBackupCrypto.readUInt32(prefix, at: 5))
            guard sealedSize >= TaptionBackupLayout.aeadOverhead,
                  sealedSize <= maxPlain + TaptionBackupLayout.aeadOverhead,
                  plainSize <= maxPlain else { throw TaptionBackupError.malformed("frame size") }
            plainTotal += plainSize
            let sealed = try handle.read(upToCount: sealedSize) ?? Data()
            guard sealed.count == sealedSize else { throw TaptionBackupError.malformed("frame truncated") }
            consumed += 9 + sealedSize
            let aad = TaptionBackupCrypto.frameAAD(
                salt: salt, month: header.month, index: index, isFinal: index == header.chunkCount - 1,
                codec: codec, plainSize: plainSize
            )
            let compressed: Data
            do {
                compressed = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key, authenticating: aad)
            } catch {
                throw TaptionBackupError.authenticationFailed
            }
            let plain = try codec.decompress(compressed, expectedSize: plainSize)
            for line in plain.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard trailer == nil else { throw TaptionBackupError.malformed("data after trailer") }
                if line.starts(with: Data("[\"#end\"".utf8)) {
                    trailer = try TaptionBackupJSONLine.parse(line)
                    continue
                }
                hasher.update(data: line)
                hasher.update(data: Data([0x0A]))
                if line.starts(with: Data("[\"r\"".utf8)) {
                    counts.readings += 1
                } else if line.starts(with: Data("[\"c\"".utf8)) {
                    counts.records += 1
                }
                try await handler(Data(line))
            }
        }
        guard consumed == header.bodyBytes, plainTotal == header.plaintextBytes,
              (try handle.read(upToCount: 1) ?? Data()).isEmpty else {
            throw TaptionBackupError.malformed("body length")
        }
        counts.contentSHA256 = TaptionBackupCrypto.hex(hasher.finalize())
        guard let trailer, trailer.count == 7,
              trailer[1].int == counts.readings, trailer[2].int == counts.records,
              trailer[5].string == counts.contentSHA256,
              header.readingCount == counts.readings, header.recordCount == counts.records,
              header.rowCount == counts.readings + counts.records,
              header.contentSHA256 == counts.contentSHA256,
              trailer[3].double == header.firstTimestamp, trailer[4].double == header.lastTimestamp,
              trailer[6].double == header.latestRecordUpdate else {
            throw TaptionBackupError.verificationFailed("trailer does not match header or content")
        }
        return counts
    }
}

/// 줄 하나가 어느 행인지(센서 원본은 id, 기록은 종류와 id)를 가리키는 열쇠와 내용 해시.
/// 월 파일 안의 행을 id 단위로 비교(포함 여부)하는 데 쓴다.
enum TaptionBackupRowIdentity {
    struct Entry: Hashable, Sendable {
        var key: String
        var isReading: Bool
    }

    private static let readingPrefix = Array("[\"r\",\"".utf8)

    /// 센서 원본 줄은 `["r","<UUID 36자>",`로 시작하므로 파싱 없이 바로 자른다. 그 밖의 줄은 파싱한다.
    static func entry(of line: Data) -> Entry? {
        let bytes = line.startIndex
        if line.count > readingPrefix.count + 36, line.prefix(readingPrefix.count).elementsEqual(readingPrefix) {
            let idStart = line.index(bytes, offsetBy: readingPrefix.count)
            let idEnd = line.index(idStart, offsetBy: 36)
            if line[idEnd] == 0x22, let id = String(data: line[idStart..<idEnd], encoding: .utf8), !id.contains("\\") {
                return Entry(key: id, isReading: true)
            }
        }
        guard let fields = try? TaptionBackupJSONLine.parse(line), fields.count >= 3,
              let id = fields[1].string else { return nil }
        switch fields[0].string {
        case "r": return Entry(key: id, isReading: true)
        case "c": return fields[2].string.map { Entry(key: "\($0)\u{0}\(id)", isReading: false) }
        default: return nil
        }
    }

    static func contentHash(_ line: Data) -> UInt64 {
        SHA256.hash(data: line).prefix(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

/// JSON Lines 한 줄(배열)을 만들고 읽는 최소 구현. 숫자는 Swift의 최단 왕복 표기라 값이 정확히 되돌아온다.
enum TaptionBackupJSONLine {
    enum Field: Equatable, Sendable {
        case null
        case string(String)
        case number(String)

        var string: String? { if case .string(let value) = self { value } else { nil } }
        var int: Int? { if case .number(let value) = self { Int(value) } else { nil } }
        var int64: Int64? { if case .number(let value) = self { Int64(value) } else { nil } }
        var double: Double? { if case .number(let value) = self { Double(value) } else { nil } }
        var isNull: Bool { if case .null = self { true } else { false } }
    }

    struct Builder {
        private var bytes: [UInt8] = [0x5B]
        private var isFirst = true

        private mutating func separate() {
            if !isFirst { bytes.append(0x2C) }
            isFirst = false
        }

        mutating func null() {
            separate()
            bytes.append(contentsOf: "null".utf8)
        }

        mutating func int(_ value: Int64) {
            separate()
            bytes.append(contentsOf: String(value).utf8)
        }

        mutating func double(_ value: Double) throws {
            guard value.isFinite else { throw TaptionBackupError.malformed("non-finite number") }
            separate()
            bytes.append(contentsOf: "\(value)".utf8)
        }

        mutating func optionalDouble(_ value: Double?) throws {
            if let value { try double(value) } else { null() }
        }

        mutating func string(_ value: String) {
            separate()
            bytes.append(0x22)
            for byte in value.utf8 {
                switch byte {
                case 0x22: bytes.append(contentsOf: [0x5C, 0x22])
                case 0x5C: bytes.append(contentsOf: [0x5C, 0x5C])
                case 0x0A: bytes.append(contentsOf: [0x5C, 0x6E])
                case 0x0D: bytes.append(contentsOf: [0x5C, 0x72])
                case 0x09: bytes.append(contentsOf: [0x5C, 0x74])
                case 0..<0x20: bytes.append(contentsOf: String(format: "\\u%04x", byte).utf8)
                default: bytes.append(byte)
                }
            }
            bytes.append(0x22)
        }

        func finish() -> Data {
            Data(bytes + [0x5D, 0x0A])
        }
    }

    static func parse<D: DataProtocol>(_ line: D) throws -> [Field] {
        let bytes = Array(line)
        var index = 0
        func skipSpaces() {
            while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x0D || bytes[index] == 0x09 { index += 1 }
        }
        func fail(_ message: String) -> TaptionBackupError { .malformed("json line: \(message)") }
        skipSpaces()
        guard index < bytes.count, bytes[index] == 0x5B else { throw fail("not an array") }
        index += 1
        var fields: [Field] = []
        skipSpaces()
        if index < bytes.count, bytes[index] == 0x5D { return [] }
        while true {
            skipSpaces()
            guard index < bytes.count else { throw fail("truncated") }
            switch bytes[index] {
            case 0x22:
                index += 1
                var output: [UInt8] = []
                var closed = false
                while index < bytes.count {
                    let byte = bytes[index]
                    index += 1
                    if byte == 0x22 { closed = true; break }
                    guard byte == 0x5C else { output.append(byte); continue }
                    guard index < bytes.count else { throw fail("bad escape") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22: output.append(0x22)
                    case 0x5C: output.append(0x5C)
                    case 0x2F: output.append(0x2F)
                    case 0x62: output.append(0x08)
                    case 0x66: output.append(0x0C)
                    case 0x6E: output.append(0x0A)
                    case 0x72: output.append(0x0D)
                    case 0x74: output.append(0x09)
                    case 0x75:
                        func unit() throws -> UInt32 {
                            guard index + 4 <= bytes.count,
                                  let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                            else { throw fail("bad unicode escape") }
                            index += 4
                            return value
                        }
                        var scalarValue = try unit()
                        if (0xD800..<0xDC00).contains(scalarValue), index + 1 < bytes.count,
                           bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                            index += 2
                            let low = try unit()
                            guard (0xDC00..<0xE000).contains(low) else { throw fail("bad surrogate") }
                            scalarValue = 0x10000 + ((scalarValue - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(scalarValue) else { throw fail("lone surrogate") }
                        output.append(contentsOf: String(Character(scalar)).utf8)
                    default: throw fail("bad escape")
                    }
                }
                guard closed else { throw fail("unterminated string") }
                fields.append(.string(String(decoding: output, as: UTF8.self)))
            case 0x6E:
                guard index + 4 <= bytes.count, Array(bytes[index..<index + 4]) == Array("null".utf8) else { throw fail("literal") }
                index += 4
                fields.append(.null)
            default:
                let start = index
                while index < bytes.count, bytes[index] != 0x2C, bytes[index] != 0x5D { index += 1 }
                let token = String(decoding: bytes[start..<index], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                guard !token.isEmpty, Double(token) != nil else { throw fail("number") }
                fields.append(.number(token))
            }
            skipSpaces()
            guard index < bytes.count else { throw fail("truncated") }
            if bytes[index] == 0x2C { index += 1; continue }
            if bytes[index] == 0x5D { return fields }
            throw fail("unexpected character")
        }
    }
}
