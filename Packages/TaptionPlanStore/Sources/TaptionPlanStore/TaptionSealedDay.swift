import Foundation

/// 확정한 날의 날씨 한 줄. 원본 `WeatherContext` 배열을 다시 훑지 않고도 배지를 그릴 수 있게 최소값만 둔다.
public struct TaptionSealedWeather: Codable, Hashable, Sendable {
    public var observedAt: Date
    public var symbolName: String
    public var condition: String
    public var temperatureCelsius: Double
    public var placeName: String?

    public init(
        observedAt: Date,
        symbolName: String,
        condition: String,
        temperatureCelsius: Double,
        placeName: String?
    ) {
        self.observedAt = observedAt
        self.symbolName = symbolName
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.placeName = placeName
    }
}

/// 확정한 하루의 요약. 하루 화면·연봉 카운터·날씨 배지가 필요로 하는 값을 한 덩어리로 담는다.
///
/// 용량을 줄이는 방법은 세 가지다.
/// 1. 원본 센서 행(수천~수만 개)을 다시 읽지 않고 이 요약 하나만 읽는다.
/// 2. 경로는 Douglas–Peucker로 단순화해 꺾은점만 남긴다(직선 구간의 점은 버린다).
/// 3. 좌표는 1e-7도 정수(Int32)로, 시각은 초 단위로 바꿔 이진 프로퍼티 리스트로 저장하고 LZFSE로 압축한다.
public struct TaptionSealedDay: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int = TaptionSealedDay.currentVersion
    public var dayStart: Date
    public var sealedAt: Date
    /// 확정할 때의 계획·장소·이동 지문. 지문이 달라지면 확정을 버리고 다시 계산한다.
    public var sourceFingerprint: String?
    /// 대분류별 시간(초). 하루 요약·연봉 카운터·달력 합계가 이 값을 그대로 쓴다.
    public var categorySeconds: [String: Int]
    /// 대분류가 아닌 달력 지표(이동거리·장소·이동 횟수·걷기/운전/대중교통 거리·외출 시간).
    /// 키는 `MapHomeCalendarTimeKind.rawValue`와 같다.
    public var metrics: [String: Double]
    public var stepCount: Int
    public var distanceMeters: Double
    public var workSeconds: Int
    public var readingCount: Int
    public var firstReadingAt: Date?
    public var lastReadingAt: Date?
    /// 단순화한 경로. `[위도0, 경도0, 위도1-위도0, …]`(1e-7도 정수) 순서의 델타 배열이다.
    public var polyline: [Int32]
    public var weather: TaptionSealedWeather?
    public var memoCount: Int
    public var actualCount: Int
    public var travelCount: Int
    public var placeCount: Int

    public init(
        version: Int = TaptionSealedDay.currentVersion,
        dayStart: Date,
        sealedAt: Date,
        sourceFingerprint: String?,
        categorySeconds: [String: Int],
        metrics: [String: Double] = [:],
        stepCount: Int,
        distanceMeters: Double,
        workSeconds: Int,
        readingCount: Int,
        firstReadingAt: Date?,
        lastReadingAt: Date?,
        polyline: [Int32],
        weather: TaptionSealedWeather?,
        memoCount: Int,
        actualCount: Int,
        travelCount: Int,
        placeCount: Int
    ) {
        self.version = version
        self.dayStart = dayStart
        self.sealedAt = sealedAt
        self.sourceFingerprint = sourceFingerprint
        self.categorySeconds = categorySeconds
        self.metrics = metrics
        self.stepCount = stepCount
        self.distanceMeters = distanceMeters
        self.workSeconds = workSeconds
        self.readingCount = readingCount
        self.firstReadingAt = firstReadingAt
        self.lastReadingAt = lastReadingAt
        self.polyline = polyline
        self.weather = weather
        self.memoCount = memoCount
        self.actualCount = actualCount
        self.travelCount = travelCount
        self.placeCount = placeCount
    }

    /// 확정한 날의 대분류별 시간(초). 화면이 쓰는 형태(`[String: TimeInterval]`)로 돌려준다.
    public var categoryDurations: [String: TimeInterval] {
        categorySeconds.mapValues { TimeInterval($0) }
    }

    /// 지문이 같으면 다시 계산하지 않는다. 지문이 없으면(예전 확정) 시각만 본다.
    public func matches(sourceFingerprint fingerprint: String?) -> Bool {
        guard let stored = sourceFingerprint, let fingerprint else { return true }
        return stored == fingerprint
    }
}
