import Foundation

/// 센서·기기 원본 이벤트 하나. 워치 요약·가속도 묶음, 기기 원시 봉투처럼 한 번 받으면 바꾸지 않는 값이다.
/// 본문(`payload`)은 JSON 문자열이라 `json_extract`로 조회할 수 있다.
public struct TaptionRawEvent: Equatable, Sendable {
    public enum Kind {
        public static let deviceEnvelope = "device-envelope"
        public static let watchSummary = "watch-summary"
        public static let watchAcceleration = "watch-acceleration"
    }

    /// 이벤트 종류. 같은 종류 안에서 `id`가 유일하다.
    public var kind: String
    public var id: String
    public var timestamp: Date
    public var sequence: Int64 = 0
    /// 자동 수집(`auto`)인지 가져온 값(`imported`)인지. 사용자가 고친 값은 이 표에 넣지 않는다.
    public var origin: TaptionStoreRecord.Origin = .auto
    /// 값이 어디서 왔는지(기기·전송 경로·가공 여부).
    public var provenance: [String] = []
    public var payload: String

    /// 저장되는 모양으로 같은지. 시각은 1970년 기준 초(저장 열)로 바뀐 값으로 비교해,
    /// 저장했다가 읽은 값과 원래 값의 마지막 비트 차이를 다른 내용으로 보지 않는다.
    public func storedFormEquals(_ other: TaptionRawEvent) -> Bool {
        kind == other.kind && id == other.id && sequence == other.sequence && origin == other.origin
            && provenance == other.provenance && payload == other.payload
            && timestamp.timeIntervalSince1970 == other.timestamp.timeIntervalSince1970
    }

    public init(
        kind: String,
        id: String,
        timestamp: Date,
        sequence: Int64 = 0,
        origin: TaptionStoreRecord.Origin = .auto,
        provenance: [String] = [],
        payload: String
    ) {
        self.kind = kind
        self.id = id
        self.timestamp = timestamp
        self.sequence = sequence
        self.origin = origin
        self.provenance = provenance
        self.payload = payload
    }
}

/// 원본 이벤트 본문의 JSON 변환. 시각은 기본(`timeIntervalSinceReferenceDate`) 방식이라 다시 읽어도 비트 단위로 같다.
/// 사람이 보는 시각은 `raw_events.ts`/`records.start_ts` 열(1970년 기준 초)에 따로 있다.
public enum TaptionRawPayloadCoding {
    public static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from payload: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return try decoder.decode(type, from: Data(payload.utf8))
    }
}
