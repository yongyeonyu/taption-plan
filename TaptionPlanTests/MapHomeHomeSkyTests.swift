import CoreLocation
import SwiftUI
import XCTest
@testable import TaptionPlan

/// 집 하늘의 천문 계산과 방향(SKY1103A01). 좌표는 공개 지명만 쓴다.
@MainActor
final class MapHomeHomeSkyTests: XCTestCase {
    private let seoul = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
    private let korea = TimeZone(identifier: "Asia/Seoul")!

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, zone: TimeZone? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone ?? korea
        return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func window(at date: Date, _ place: CLLocationCoordinate2D) -> MapHomeSkyWindow {
        MapHomeSkyWindow(
            dayNumber: MapHomeAstronomy.solarDayNumber(at: date, longitude: place.longitude),
            latitude: place.latitude,
            longitude: place.longitude
        )
    }

    private func state(at date: Date, _ place: CLLocationCoordinate2D) -> MapHomeSkyState {
        MapHomeSkyState(date: date, window: window(at: date, place))
    }

    /// 천문연구원이 공개한 서울 일출·일몰과 3분 안에서 맞고, 정오 고도도 맞는다.
    func testSeoulSolsticesAndEquinoxMatchPublishedTimes() throws {
        let cases: [(Date, Date, Date, Double)] = [
            (date(2025, 3, 20), date(2025, 3, 20, 6, 35), date(2025, 3, 20, 18, 42), 52.4),
            (date(2025, 6, 21), date(2025, 6, 21, 5, 11), date(2025, 6, 21, 19, 57), 75.9),
            (date(2025, 12, 22), date(2025, 12, 22, 7, 43), date(2025, 12, 22, 17, 17), 29.0)
        ]
        for (day, rise, set, noonAltitude) in cases {
            let today = window(at: day, seoul).today
            XCTAssertEqual(try XCTUnwrap(today.sunrise).timeIntervalSince(rise), 0, accuracy: 180, "\(day) 일출")
            XCTAssertEqual(try XCTUnwrap(today.sunset).timeIntervalSince(set), 0, accuracy: 180, "\(day) 일몰")
            XCTAssertEqual(state(at: today.noon, seoul).altitude, noonAltitude, accuracy: 0.6, "\(day) 정오 고도")
        }
    }

    func testPhaseFollowsSunriseAndSunset() throws {
        let today = window(at: date(2025, 6, 21), seoul).today
        let rise = try XCTUnwrap(today.sunrise), set = try XCTUnwrap(today.sunset)
        XCTAssertEqual(state(at: date(2025, 6, 21, 1), seoul).phase, .night)
        XCTAssertEqual(state(at: rise.addingTimeInterval(-20 * 60), seoul).phase, .dawn)
        XCTAssertEqual(state(at: rise.addingTimeInterval(5 * 60), seoul).phase, .sunrise)
        XCTAssertEqual(state(at: today.noon, seoul).phase, .day)
        XCTAssertEqual(state(at: set.addingTimeInterval(-5 * 60), seoul).phase, .sunset)
        XCTAssertEqual(state(at: set.addingTimeInterval(20 * 60), seoul).phase, .dusk)
        XCTAssertEqual(state(at: date(2025, 6, 21, 23), seoul).phase, .night)
    }

    /// 해는 동쪽 도시에서 먼저 뜨고 먼저 진다.
    func testSunReachesEastBeforeWest() throws {
        let day = date(2025, 3, 20)
        let east = window(at: day, .init(latitude: 35.18, longitude: 129.08)).today // 부산
        let west = window(at: day, .init(latitude: 35.16, longitude: 126.85)).today // 광주
        let lead = (129.08 - 126.85) * 4 * 60
        XCTAssertEqual(try XCTUnwrap(west.sunrise).timeIntervalSince(try XCTUnwrap(east.sunrise)), lead, accuracy: 30)
        XCTAssertEqual(try XCTUnwrap(west.sunset).timeIntervalSince(try XCTUnwrap(east.sunset)), lead, accuracy: 30)
    }

    /// 북쪽 위 지도에서 해·달은 오른쪽(동)에서 떠서 왼쪽(서)으로 넘어가고, 남쪽 위면 반대다.
    func testArcRunsRightToLeftAndFollowsMapHeading() {
        typealias Layout = MapHomeHomeSkyLayout
        let peak = Layout.peak(noonAltitude: 60)
        let rise = Layout.point(progress: 0, peak: peak, headingDegrees: 0)
        let top = Layout.point(progress: 0.5, peak: peak, headingDegrees: 0)
        let set = Layout.point(progress: 1, peak: peak, headingDegrees: 0)
        XCTAssertGreaterThan(rise.x, top.x)
        XCTAssertGreaterThan(top.x, set.x)
        XCTAssertEqual(top.x, 39, accuracy: 0.001)
        XCTAssertEqual(rise.y, Layout.horizonY, accuracy: 0.001)
        XCTAssertLessThan(top.y, rise.y)
        XCTAssertGreaterThan(Layout.point(progress: -0.1, peak: peak, headingDegrees: 0).y, Layout.horizonY)

        let flipped = Layout.point(progress: 0, peak: peak, headingDegrees: 180)
        XCTAssertLessThan(flipped.x, top.x)
        XCTAssertEqual(Layout.point(progress: 0, peak: peak, headingDegrees: 90).x, 39, accuracy: 0.001)
        // 45° 돌아도 호 폭은 그대로다. 동쪽이 위아래에 가까울 때만 좁아진다.
        XCTAssertEqual(Layout.point(progress: 0, peak: peak, headingDegrees: 45).x, rise.x, accuracy: 0.001)
    }

    /// 해가 뜨는 순간 달은 진다. 해가 지는 순간 달이 뜬다.
    func testMoonSetsAsSunRisesAndRisesAsSunSets() throws {
        let today = window(at: date(2025, 3, 20), seoul).today
        let atRise = state(at: try XCTUnwrap(today.sunrise), seoul)
        XCTAssertEqual(try XCTUnwrap(atRise.sunProgress), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(atRise.moonProgress), 1, accuracy: 0.001)
        let atSet = state(at: try XCTUnwrap(today.sunset).addingTimeInterval(1), seoul)
        XCTAssertEqual(try XCTUnwrap(atSet.sunProgress), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(atSet.moonProgress), 0, accuracy: 0.001)
        // 자정 넘어도 달의 호는 끊기지 않고 이어진다.
        let beforeMidnight = state(at: date(2025, 3, 20, 23, 50), seoul)
        let afterMidnight = state(at: date(2025, 3, 21, 0, 10), seoul)
        XCTAssertLessThan(try XCTUnwrap(beforeMidnight.moonProgress), try XCTUnwrap(afterMidnight.moonProgress))
        XCTAssertEqual(try XCTUnwrap(afterMidnight.moonProgress) - beforeMidnight.moonProgress!, 0.03, accuracy: 0.02)
    }

    /// 백야·극야에서는 일출·일몰이 없어도 값이 끊기지 않는다.
    func testPolarExtremes() throws {
        let svalbard = CLLocationCoordinate2D(latitude: 78.22, longitude: 15.65) // 롱위에아르뷔엔
        let summer = date(2025, 6, 21, 12, 0, zone: .gmt)
        XCTAssertNil(window(at: summer, svalbard).today.sunrise)
        XCTAssertNil(window(at: summer, svalbard).today.sunset)
        for hour in stride(from: 0, to: 24, by: 3) {
            let sky = state(at: date(2025, 6, 21, hour, 0, zone: .gmt), svalbard)
            XCTAssertGreaterThan(sky.altitude, 0)
            XCTAssertNil(sky.moonProgress)
            XCTAssertNotEqual(sky.phase, .night)
            XCTAssertTrue((0...1).contains(try XCTUnwrap(sky.sunProgress)))
        }
        let winter = date(2025, 12, 21, 12, 0, zone: .gmt)
        XCTAssertNil(window(at: winter, svalbard).today.sunrise)
        for hour in stride(from: 0, to: 24, by: 3) {
            let sky = state(at: date(2025, 12, 21, hour, 0, zone: .gmt), svalbard)
            XCTAssertLessThan(sky.altitude, 0)
            XCTAssertNil(sky.sunProgress)
            XCTAssertTrue((0...1).contains(try XCTUnwrap(sky.moonProgress)))
        }
        // 극점과 날짜 변경선에서도 NaN이 없다.
        for place in [CLLocationCoordinate2D(latitude: 90, longitude: 0), .init(latitude: -90, longitude: 180), .init(latitude: 0, longitude: -180)] {
            let sky = state(at: summer, place)
            XCTAssertTrue(sky.altitude.isFinite)
            XCTAssertTrue(sky.daylight.isFinite)
        }
        // 남반구는 6월이 낮이 짧고 북반구보다 해가 낮다.
        let sydney = CLLocationCoordinate2D(latitude: -33.87, longitude: 151.21)
        let june = window(at: summer, sydney).today
        XCTAssertLessThan(try XCTUnwrap(june.sunset).timeIntervalSince(try XCTUnwrap(june.sunrise)), 11 * 3_600)
    }

    /// 일식·월식이 있었던 시각으로 위상을 맞춘다.
    func testMoonPhaseMatchesKnownEvents() {
        let new = MapHomeAstronomy.moonPhase(at: date(2026, 8, 12, 17, 46, zone: .gmt)) // 개기일식
        XCTAssertLessThan(new.illumination, 0.002)
        let full = MapHomeAstronomy.moonPhase(at: date(2025, 3, 14, 6, 58, zone: .gmt)) // 개기월식
        XCTAssertGreaterThan(full.illumination, 0.998)
        let first = MapHomeAstronomy.moonPhase(at: date(2025, 4, 5, 2, 15, zone: .gmt)) // 상현
        XCTAssertEqual(first.illumination, 0.5, accuracy: 0.03)
        XCTAssertTrue(first.isWaxing)
        let last = MapHomeAstronomy.moonPhase(at: date(2025, 4, 21, 1, 36, zone: .gmt)) // 하현
        XCTAssertEqual(last.illumination, 0.5, accuracy: 0.03)
        XCTAssertFalse(last.isWaxing)
    }

    /// 프레임마다 읽어도 하루·위치가 바뀔 때만 계산한다.
    func testWindowComputesOnlyWhenDayOrPlaceChanges() {
        let start = date(2031, 5, 5)
        let busan = CLLocationCoordinate2D(latitude: 35.18, longitude: 129.08)
        _ = MapHomeSkyWindow.current(at: start, coordinate: seoul)
        let before = MapHomeSkyWindow.computeCount
        for minute in 0..<60 {
            _ = MapHomeSkyWindow.current(at: start.addingTimeInterval(Double(minute) * 60), coordinate: seoul)
        }
        XCTAssertEqual(MapHomeSkyWindow.computeCount, before)
        _ = MapHomeSkyWindow.current(at: start, coordinate: busan)
        XCTAssertEqual(MapHomeSkyWindow.computeCount, before + 1)
        _ = MapHomeSkyWindow.current(at: start.addingTimeInterval(86_400), coordinate: busan)
        XCTAssertEqual(MapHomeSkyWindow.computeCount, before + 2)
    }

    /// 재생 분 > 고른 분 > 오늘이면 지금 > 지난 날이면 23:59.
    func testDisplayDatePriority() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = korea
        let now = date(2026, 11, 3, 15, 20)
        let today = MapHomeHomeSkyInput(coordinate: seoul, selectedDay: now)
        XCTAssertEqual(today.displayDate(now: now, calendar: calendar), now)
        let past = MapHomeHomeSkyInput(coordinate: seoul, selectedDay: date(2026, 11, 1))
        XCTAssertEqual(past.displayDate(now: now, calendar: calendar), date(2026, 11, 1, 23, 59))

        let progress = MapHomePlaybackProgress()
        let picked = MapHomeHomeSkyInput(coordinate: seoul, selectedDay: date(2026, 11, 1), progress: progress)
        progress.rawSelectedMinute = 6 * 60
        XCTAssertEqual(picked.displayDate(now: now, calendar: calendar), date(2026, 11, 1, 6, 0))
        progress.rawCurrentMinute = 7 * 60 + 30
        XCTAssertEqual(picked.displayDate(now: now, calendar: calendar), date(2026, 11, 1, 7, 30))
        progress.rawCurrentMinute = 1_440
        XCTAssertEqual(picked.displayDate(now: now, calendar: calendar), date(2026, 11, 1, 23, 59))
    }

    // MARK: - 눈으로 보는 시트

    private struct Tile: View {
        let state: MapHomeSkyState
        let kind: MapHomeHomeWeatherKind
        var heading = 0.0
        var sec = 5.0
        var level = 120

        var body: some View {
            ZStack {
                Circle().fill(Color(hex: "#FDF8EC"))
                MapHomeHomeSkyFrame(state: state, kind: kind, sec: sec, headingDegrees: heading)
                Image(MapHomeGrowthPolicy.artworkName(level: level))
                    .resizable().scaledToFit()
                    .frame(width: MapHomePlacePinLayout.artworkSize, height: MapHomePlacePinLayout.artworkSize)
                MapHomeHomeWeatherFrame(kind: kind, sec: sec, shade: MapHomeSkyShade(state: state))
                VStack {
                    Text("19°")
                        .font(.taptionFixed(size: 11, weight: .heavy))
                        .foregroundStyle(Color(hex: "#3E2C22"))
                        .shadow(color: .white, radius: 1.2)
                        .shadow(color: .white, radius: 1.2)
                        .padding(.top, MapHomePlacePinLayout.temperatureTopInset)
                    Spacer(minLength: 0)
                }
            }
            .frame(width: MapHomePlacePinLayout.avatarSize, height: MapHomePlacePinLayout.avatarSize)
            .clipShape(Circle())
            .overlay { Circle().stroke(Color.white.opacity(0.92), lineWidth: 2) }
        }
    }

    private func writeSheet<V: View>(_ name: String, _ view: V) throws {
        guard let directory = ProcessInfo.processInfo.environment["SKY_SHEET_DIR"] else {
            throw XCTSkip("SKY_SHEET_DIR가 없으면 시트를 만들지 않는다")
        }
        let renderer = ImageRenderer(content: view.padding(10).background(Color(hex: "#E8E4DA")))
        renderer.scale = 3
        let data = try XCTUnwrap(renderer.uiImage?.pngData())
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private static func label(_ text: String, width: CGFloat = 78) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).frame(width: width).foregroundStyle(.black)
    }

    func testRenderSkySheets() throws {
        let seoul = self.seoul
        let sky: (Date) -> MapHomeSkyState = { [self] in state(at: $0, seoul) }
        let today = window(at: date(2026, 3, 20), seoul).today
        let rise = try XCTUnwrap(today.sunrise), set = try XCTUnwrap(today.sunset)
        let times: [(String, Date)] = [
            ("새벽", rise.addingTimeInterval(-25 * 60)),
            ("일출", rise.addingTimeInterval(4 * 60)),
            ("낮", today.noon.addingTimeInterval(-90 * 60)),
            ("일몰", set.addingTimeInterval(-6 * 60)),
            ("노을", set.addingTimeInterval(18 * 60)),
            ("밤", set.addingTimeInterval(4 * 3_600))
        ]
        let kinds: [(String, MapHomeHomeWeatherKind)] = [("맑음", .sun), ("흐림", .cloud), ("비", .rain), ("눈", .snow)]
        try writeSheet("sky-times-weather.png", VStack(spacing: 6) {
            HStack(spacing: 6) {
                Self.label("", width: 26)
                ForEach(times, id: \.0) { Self.label($0.0) }
            }
            ForEach(kinds, id: \.0) { kind in
                HStack(spacing: 6) {
                    Self.label(kind.0, width: 26)
                    ForEach(times, id: \.0) { Tile(state: sky($0.1), kind: kind.1) }
                }
            }
        })

        let hours = stride(from: 0, to: 24, by: 2).map { [self] hour in (hour, date(2026, 3, 20, hour)) }
        try writeSheet("sky-day-heading.png", VStack(spacing: 6) {
            ForEach([0.0, 180.0, 90.0], id: \.self) { heading in
                HStack(spacing: 4) {
                    Self.label("\(Int(heading))°", width: 26)
                    ForEach(hours, id: \.0) { item in
                        VStack(spacing: 2) {
                            Tile(state: sky(item.1), kind: .sun, heading: heading)
                            Self.label("\(item.0)시")
                        }
                    }
                }
            }
        })

        let phases = (0..<8).map { [self] in date(2026, 11, 9, 22).addingTimeInterval(Double($0) * 4 * 86_400) }
        try writeSheet("sky-moon-phases.png", HStack(spacing: 4) {
            ForEach(Array(phases.enumerated()), id: \.0) { _, day in
                let night = sky(day)
                VStack(spacing: 2) {
                    Tile(state: night, kind: .moon)
                    Self.label("\(Int(night.moon.illumination * 100))% \(night.moon.isWaxing ? "차" : "기")")
                }
            }
        })

        let levels = [14, 120, 157, 335, 361]
        try writeSheet("sky-levels.png", VStack(spacing: 6) {
            ForEach(levels, id: \.self) { level in
                HStack(spacing: 6) {
                    Self.label("Lv.\(level)", width: 26)
                    ForEach(times, id: \.0) { Tile(state: sky($0.1), kind: .sun, level: level) }
                }
            }
        })

        let motion = (0..<8).map { Double($0) * 0.6 }
        try writeSheet("sky-motion.png", VStack(spacing: 6) {
            ForEach([("일출", rise.addingTimeInterval(3 * 60)), ("일몰", set.addingTimeInterval(-3 * 60)), ("밤", set.addingTimeInterval(4 * 3_600))], id: \.0) { row in
                HStack(spacing: 4) {
                    Self.label(row.0, width: 26)
                    ForEach(motion, id: \.self) { sec in
                        Tile(state: sky(row.1), kind: .sun, sec: 13 * 3 + sec)
                    }
                }
            }
        })
    }
}
