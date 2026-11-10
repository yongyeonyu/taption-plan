import Foundation
import TaptionPlanCore

/// 철도 구간을 정렬해 두고 머문 자리가 지나간 것인지 찾는다(지하철 통과 제외, 대표 지시).
struct MapHomeRailIndex: Sendable {
    private static let shortStay: TimeInterval = 10 * 60
    private static let transferStay: TimeInterval = 30 * 60
    private static let adjacentGap: TimeInterval = 10 * 60

    private let spans: [TimeSpan]
    private let spanEnds: [Date]
    private let starts: [Date]
    private let ends: [Date]

    init(travel: [TravelSegment]) {
        let rails = travel.filter { $0.mode == .subway || $0.mode == .train }.map(\.span)
        var merged: [TimeSpan] = []
        for span in rails.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1] = TimeSpan(start: last.start, end: max(last.end, span.end))
            } else {
                merged.append(span)
            }
        }
        spans = merged
        spanEnds = merged.map(\.end)
        starts = rails.map(\.start).sorted()
        ends = rails.map(\.end).sorted()
    }

    func isPassThrough(_ stay: TimeSpan) -> Bool {
        guard !spans.isEmpty else { return false }
        let duration = stay.end.timeIntervalSince(stay.start)
        let overlap = overlap(with: stay)
        if overlap > 0, overlap * 2 >= duration { return true }
        let arrived = Self.hasValue(in: ends, near: stay.start)
        let left = Self.hasValue(in: starts, near: stay.end)
        return (arrived && left && duration < Self.transferStay) || ((arrived || left) && duration < Self.shortStay)
    }

    private func overlap(with stay: TimeSpan) -> TimeInterval {
        var total: TimeInterval = 0
        var index = Self.firstIndex(in: spanEnds, notBefore: stay.start)
        while index < spans.count, spans[index].start < stay.end {
            total += max(0, min(spans[index].end, stay.end).timeIntervalSince(max(spans[index].start, stay.start)))
            index += 1
        }
        return total
    }

    private static func hasValue(in sorted: [Date], near date: Date) -> Bool {
        let index = firstIndex(in: sorted, notBefore: date.addingTimeInterval(-adjacentGap))
        return index < sorted.count && sorted[index].timeIntervalSince(date) <= adjacentGap
    }

    private static func firstIndex(in sorted: [Date], notBefore date: Date) -> Int {
        var low = 0, high = sorted.count
        while low < high {
            let middle = (low + high) / 2
            if sorted[middle] < date { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// 걷기 구간. 공항·해외 도시는 그 자리에서 걸은 흔적이 있어야 다녀온 곳이다(대표 지시, VIS1110A03).
struct MapHomeWalkIndex: Sendable {
    private static let margin: TimeInterval = 10 * 60
    private static let minimumMeters = 50.0
    private let starts: [Date]
    private let ends: [Date]

    init(travel: [TravelSegment]) {
        let walks = travel.filter { $0.mode == .walking && $0.distanceMeters >= Self.minimumMeters }.map(\.span).sorted { $0.start < $1.start }
        starts = walks.map(\.start)
        var latest = Date.distantPast
        ends = walks.map { latest = max(latest, $0.end); return latest }
    }

    /// 머문 앞뒤 10분 안에 걷기가 걸쳐 있는지.
    func hasWalk(around stay: TimeSpan) -> Bool {
        let windowStart = stay.start.addingTimeInterval(-Self.margin), windowEnd = stay.end.addingTimeInterval(Self.margin)
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] < windowEnd { low = middle + 1 } else { high = middle }
        }
        return low > 0 && ends[low - 1] > windowStart
    }
}

/// 명소를 격자에 넣어 머문 자리 둘레 명소만 비교한다.
struct MapHomePlaceSiteIndex: Sendable {
    private struct Entry: Sendable {
        let place: MapHomeKoreaPlace
        let site: MapHomeLandmarkSite
    }

    private static let cellDegrees = 0.1
    private let cells: [Int: [Entry]]

    static let shared = MapHomePlaceSiteIndex(places: MapHomeKoreaPlaceBookData.places)

    init(places: [MapHomeKoreaPlace]) {
        var cells: [Int: [Entry]] = [:]
        for place in places {
            for site in [place.site] + place.airports.map(\.site) {
                let latitudeReach = site.reachMeters / 111_000
                let longitudeReach = latitudeReach / max(0.05, cos(site.latitude * .pi / 180))
                for row in Self.cellRange(site.latitude, reach: latitudeReach) {
                    for column in Self.cellRange(site.longitude, reach: longitudeReach) {
                        cells[Self.key(row, column), default: []].append(Entry(place: place, site: site))
                    }
                }
            }
        }
        self.cells = cells
    }

    /// 이 자리를 덮는 명소. 공항이 여럿이어도 한 번만 돌려준다.
    func places(containing point: GeoPoint) -> [MapHomeKoreaPlace] {
        let row = Self.cell(point.latitude), column = Self.cell(point.longitude)
        var seen = Set<String>()
        return (cells[Self.key(row, column)] ?? []).compactMap { entry in
            entry.site.contains(point) && seen.insert(entry.place.id).inserted ? entry.place : nil
        }
    }

    private static func cell(_ degrees: Double) -> Int { Int((degrees / cellDegrees).rounded(.down)) }
    private static func cellRange(_ degrees: Double, reach: Double) -> ClosedRange<Int> { cell(degrees - reach)...cell(degrees + reach) }
    private static func key(_ row: Int, _ column: Int) -> Int { row * 100_000 + column }
}

/// 도감과 여권이 함께 쓰는 방문 장부(LDG1110A01). 원본에서 만드는 파생값이라 저장 형식을 바꾸지 않는다.
enum MapHomeVisitLedger {
    nonisolated static func build(
        stays: [PlaceStay],
        travel: [TravelSegment],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String: [Date]] {
        let sites = MapHomePlaceSiteIndex.shared, rails = MapHomeRailIndex(travel: travel), walks = MapHomeWalkIndex(travel: travel)
        var days: [String: Set<Date>] = [:]
        for stay in stays {
            guard let point = stay.point else { continue }
            let matches = sites.places(containing: point).filter {
                stay.span.end.timeIntervalSince(stay.span.start) >= $0.minimumVisitSeconds
                    && (!$0.usesPassportStamp || walks.hasWalk(around: stay.span))
            }
            guard !matches.isEmpty, !rails.isPassThrough(stay.span) else { continue }
            let day = calendar.startOfDay(for: stay.span.start)
            for place in matches { days[place.id, default: []].insert(day) }
        }
        return days.mapValues { $0.sorted() }
    }

    /// 드라이브길 통과·시험 방문을 더한다. 하루에 여러 번이어도 한 번이다.
    nonisolated static func merged(
        _ visits: [String: [Date]],
        extra: [String: [Date]],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String: [Date]] {
        visits.merging(extra.mapValues { $0.map(calendar.startOfDay) }) { Set($0 + $1).sorted() }
            .mapValues { Set($0).sorted() }
    }
}

/// 장부와 드라이브길 통과를 메인 스레드 밖에서 만들고 재사용한다.
actor MapHomeVisitLedgerStore {
    struct DriveState: Codable, Equatable {
        var passes: [String: Date] = [:]
        var processedThrough: Date = .distantPast
    }

    static let shared = MapHomeVisitLedgerStore()

    private var cached: (revision: UInt64, visits: [String: [Date]])?
    private var drive: DriveState?
    private(set) var isRefreshingDrive = false

    private var driveFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("place-book-drive-passes.json")
    }

    func visits(revision: UInt64, stays: [PlaceStay], travel: [TravelSegment]) -> [String: [Date]] {
        if let cached, cached.revision == revision { return cached.visits }
        let visits = MapHomeVisitLedger.build(stays: stays, travel: travel)
        cached = (revision, visits)
        return visits
    }

    func driveState() -> DriveState {
        if let drive { return drive }
        let loaded = (try? Data(contentsOf: driveFile)).flatMap { try? JSONDecoder().decode(DriveState.self, from: $0) } ?? DriveState()
        drive = loaded
        return loaded
    }

    /// 다른 화면이 이미 갱신 중이면 false다.
    func beginDriveRefresh() -> Bool {
        guard !isRefreshingDrive else { return false }
        isRefreshingDrive = true
        return true
    }

    func endDriveRefresh() {
        isRefreshingDrive = false
        saveDrive()
    }

    func recordDrive(readings: [SensorReading], through end: Date) {
        var state = driveState()
        MapHomePlaceBookDrivePass.merge(readings: readings, into: &state.passes)
        state.processedThrough = max(state.processedThrough, end)
        drive = state
    }

    /// 기록을 모두 지우거나 백업을 복원하면 부른다. 지운 기록에서 나온 도장과 처리 시각을 남기지 않는다(REV1110A02).
    func reset() {
        cached = nil
        drive = DriveState()
        try? FileManager.default.removeItem(at: driveFile)
    }

    func saveDrive() {
        guard let drive, let data = try? JSONEncoder().encode(drive) else { return }
        try? data.write(to: driveFile, options: .atomic)
    }
}

/// 도감·여권이 방문을 받는 곳. 저장된 값을 먼저 주고, 새로 찾은 값은 뒤에 준다.
struct MapHomeVisitSource {
    var cached: () async -> [String: [Date]]
    var refreshed: () async -> [String: [Date]]

    static func fixed(stays: [PlaceStay]) -> Self {
        let load: () async -> [String: [Date]] = { MapHomeVisitLedger.build(stays: stays, travel: []) }
        return Self(cached: load, refreshed: load)
    }
}

extension AppModel {
    var placeBookVisitSource: MapHomeVisitSource {
        MapHomeVisitSource(cached: { await self.placeBookCachedVisits() }, refreshed: { await self.placeBookRefreshedVisits() })
    }

    /// 메뉴를 열 때 미리 만들어 두면 도감·여권이 바로 뜬다.
    func prewarmPlaceBookVisits() {
        Task(priority: .utility) { _ = await placeBookCachedVisits() }
    }

    private func placeBookBaseVisits() async -> [String: [Date]] {
        await MapHomeVisitLedgerStore.shared.visits(revision: snapshotContentRevision, stays: snapshot.places, travel: snapshot.travel)
    }

    private func placeBookCachedVisits() async -> [String: [Date]] {
        let base = await placeBookBaseVisits()
        let drive = await MapHomeVisitLedgerStore.shared.driveState()
        return MapHomeVisitLedger.merged(base, extra: drive.passes.mapValues { [$0] })
    }

    /// 처리한 시각 이후의 이동 구간만 읽는다. 중간에 닫혀도 다음에 이어 간다.
    private func placeBookRefreshedVisits() async -> [String: [Date]] {
        let store = MapHomeVisitLedgerStore.shared
        if await store.beginDriveRefresh() {
            let through = await store.driveState().processedThrough
            let spans = snapshot.travel
                .filter { $0.mode != .walking && $0.mode != .subway && $0.span.end > through && $0.span.end <= .now }
                .map(\.span).sorted { $0.end < $1.end }
            for (index, span) in spans.enumerated() {
                if Task.isCancelled { break }
                await store.recordDrive(readings: await sensorReadings(in: span), through: span.end)
                if index % 20 == 19 { await store.saveDrive() }
            }
            await store.endDriveRefresh()
        }
        return await placeBookCachedVisits()
    }
}

/// 도감 판정 점검(VIS1110A02). `-placeBookAudit`로 켤 때만 앱 폴더에 적고, 밖으로 보내지 않는다.
extension AppModel {
    static let placeBookAuditIDs = ["kr.airport_gmp", "kr.yeongjongdo"]

    /// 고치기 전 판정(반경 3km·15km 원)으로 후보를 모아 지금 판정과 견준다.
    private static func circleContains(_ site: MapHomeLandmarkSite, _ point: GeoPoint) -> Bool {
        let legacy = site.outline != nil ? 15_000.0 : 3_000
        return MapHomeLandmarkSite.distance(point.latitude, point.longitude, site.latitude, site.longitude) <= max(site.radiusMeters, legacy)
    }

    func runPlaceBookAuditIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-placeBookAudit") else { return }
        for _ in 0..<60 where snapshot.places.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        let places = MapHomeKoreaPlaceBookData.places.filter { Self.placeBookAuditIDs.contains($0.id) }
        let rails = MapHomeRailIndex(travel: snapshot.travel), walks = MapHomeWalkIndex(travel: snapshot.travel)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        var rows: [[String: Any]] = []
        for stay in snapshot.places {
            guard let point = stay.point else { continue }
            let byCircle = places.filter { place in
                ([place.site] + place.airports.map(\.site)).contains { Self.circleContains($0, point) }
            }
            for place in byCircle {
                let matched = MapHomePlaceSiteIndex.shared.places(containing: point).contains { $0.id == place.id }
                let near = snapshot.travel.filter {
                    $0.span.end > stay.span.start.addingTimeInterval(-3_600) && $0.span.start < stay.span.end.addingTimeInterval(3_600)
                }.sorted { $0.span.start < $1.span.start }
                rows.append([
                    "place": place.id,
                    "start": formatter.string(from: stay.span.start),
                    "end": formatter.string(from: stay.span.end),
                    "minutes": Int(stay.span.end.timeIntervalSince(stay.span.start) / 60),
                    "name": stay.displayName,
                    "building": stay.buildingName ?? "",
                    "meters": Int(MapHomeLandmarkSite.distance(point.latitude, point.longitude, place.latitude, place.longitude)),
                    "accuracy": Int(point.horizontalAccuracy),
                    "insideSite": matched,
                    "walked": walks.hasWalk(around: stay.span),
                    "railPass": rails.isPassThrough(stay.span),
                    "countsAsVisit": matched && stay.span.end.timeIntervalSince(stay.span.start) >= place.minimumVisitSeconds
                        && !rails.isPassThrough(stay.span) && (!place.usesPassportStamp || walks.hasWalk(around: stay.span)),
                    "travel": near.map { "\($0.mode.rawValue) \(formatter.string(from: $0.span.start))~\(formatter.string(from: $0.span.end)) \(Int($0.distanceMeters))m" },
                ])
            }
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaptionPlan/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let summary: [String: Any] = ["stays": snapshot.places.count, "travel": snapshot.travel.count, "rows": rows]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("place-book-audit.json"), options: .atomic)
        }
    }
}
