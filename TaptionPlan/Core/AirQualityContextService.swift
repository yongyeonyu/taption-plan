import CoreLocation
import Foundation
import TaptionPlanCore

actor AirQualityContextService {
    private struct CachedContext {
        var location: CLLocation
        var context: AirQualityContext
    }

    private let session: URLSession
    /// The data.go.kr key lives only on the relay server, never in the app.
    private let proxyBaseURL: URL?
    private var stations: [AirKoreaStation] = []
    private var stationsLoadedAt: Date?
    private var cachedContext: CachedContext?

    init(
        session: URLSession = .shared,
        proxyBaseURL: URL? = AirQualityContextService.configuredProxyBaseURL()
    ) {
        self.session = session
        self.proxyBaseURL = proxyBaseURL
    }

    func context(
        latitude: Double,
        longitude: Double,
        at date: Date = .now
    ) async throws -> AirQualityContext {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        if let cachedContext,
           date.timeIntervalSince(cachedContext.context.observedAt) < 30 * 60,
           location.distance(from: cachedContext.location) < 3_000 {
            return cachedContext.context
        }

        if isInSouthKorea(latitude: latitude, longitude: longitude),
           let proxyBaseURL,
           let context = try? await airKoreaContext(
                latitude: latitude,
                longitude: longitude,
                proxyBaseURL: proxyBaseURL,
                at: date
           ) {
            cachedContext = CachedContext(location: location, context: context)
            return context
        }

        // 상업 이용이 가능한 해외 대기질 제공원이 없으므로 국내 에어코리아
        // 자료만 사용한다. 자료가 없으면 대기질을 비워 둔다.
        throw AirQualityServiceError.noProvider
    }

    /// Host name only (a build setting cannot hold `https://` without escaping).
    static func configuredProxyBaseURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment["AIR_QUALITY_PROXY_HOST"]
        let bundled = Bundle.main.object(forInfoDictionaryKey: "AIR_QUALITY_PROXY_HOST") as? String
        return proxyBaseURL(host: environment ?? bundled)
    }

    static func proxyBaseURL(host: String?) -> URL? {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty, !host.hasPrefix("$("),
              !host.contains("/"), !host.contains(":"), !host.contains(" ") else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        return components.url
    }

    private func airKoreaContext(
        latitude: Double,
        longitude: Double,
        proxyBaseURL: URL,
        at date: Date
    ) async throws -> AirQualityContext {
        if stations.isEmpty
            || stationsLoadedAt.map({ date.timeIntervalSince($0) > 30 * 86_400 }) == true {
            stations = try await loadStations(proxyBaseURL: proxyBaseURL)
            stationsLoadedAt = date
        }
        let origin = CLLocation(latitude: latitude, longitude: longitude)
        guard let station = stations.min(by: {
            origin.distance(from: $0.location)
                < origin.distance(from: $1.location)
        }) else {
            throw AirQualityServiceError.noStation
        }

        var components = URLComponents(
            url: proxyBaseURL.appendingPathComponent("airkorea/measurement"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "stationName", value: station.name)]
        guard let url = components?.url else {
            throw AirQualityServiceError.invalidRequest
        }
        let payload: AirKoreaEnvelope<AirKoreaMeasurement> = try await fetch(url)
        guard let item = payload.response.body.items.first,
              let pm10 = Double(item.pm10Value),
              let pm25 = Double(item.pm25Value) else {
            throw AirQualityServiceError.invalidResponse
        }
        return AirQualityContext(
            pm10MicrogramsPerCubicMeter: pm10,
            pm25MicrogramsPerCubicMeter: pm25,
            observedAt: AirKoreaDateParser.date(item.dataTime) ?? date,
            stationName: station.name,
            providerName: "에어코리아",
            isFallback: false
        )
    }

    private func loadStations(proxyBaseURL: URL) async throws -> [AirKoreaStation] {
        let url = proxyBaseURL.appendingPathComponent("airkorea/stations")
        let payload: AirKoreaEnvelope<AirKoreaStationPayload> = try await fetch(url)
        return payload.response.body.items.compactMap { item in
            guard let latitude = Double(item.dmX),
                  let longitude = Double(item.dmY) else { return nil }
            return AirKoreaStation(
                name: item.stationName,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw AirQualityServiceError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func isInSouthKorea(latitude: Double, longitude: Double) -> Bool {
        (32...39.5).contains(latitude) && (124...132).contains(longitude)
    }
}

private enum AirQualityServiceError: Error {
    case invalidRequest
    case invalidResponse
    case noStation
    case noProvider
}

private struct AirKoreaEnvelope<Item: Decodable>: Decodable {
    struct Response: Decodable {
        struct Body: Decodable {
            var items: [Item]
        }
        var body: Body
    }
    var response: Response
}

private struct AirKoreaStationPayload: Decodable {
    var stationName: String
    var dmX: String
    var dmY: String
}

private struct AirKoreaStation {
    var name: String
    var latitude: Double
    var longitude: Double

    var location: CLLocation {
        CLLocation(latitude: latitude, longitude: longitude)
    }
}

private struct AirKoreaMeasurement: Decodable {
    var dataTime: String
    var pm10Value: String
    var pm25Value: String
}

private enum AirKoreaDateParser {
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)
    }
}
