import CoreLocation
import CryptoKit
import MapKit

/// 등록되지 않은 체류 자리의 가장 가까운 장소 이름을 지도에서 찾는다(NLE1104A02).
/// 이름만 메모리에 잠시 두며 기록에는 쓰지 않는다. 찾지 못하면 체류의 원래 이름을 쓴다.
@MainActor
enum NLENearbyPlaceNames {
    /// 한 번에 찾는 곳 수. MapKit 호출 제한을 넘지 않게 오래 머문 곳부터 찾는다.
    static let maximumLookups = 12
    private static let searchRadiusMeters: CLLocationDistance = 200
    private static let cacheLimit = 300
    private static let storageKey = "stayPlaceNames"
    /// 찾은 이름은 기기에 기억한다(KKP1113A01). 카카오는 하루 호출 수가 정해져 있어 같은 곳을 다시 묻지 않는다.
    private static var cache: [String: String] = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]

    /// 기억한 이름(약 50m 칸 열쇠 → 이름).
    static var storedNames: [String: String] { cache }

    private static let candidateKey = "stayPlaceCandidates"
    /// 카카오에서 받은 그 자리 가게 후보(SPC1114A01). 기록 이름 고르기·식사 판단·후보 목록에 쓴다.
    private(set) static var storedCandidates: [String: [StayPlaceCandidate]] = UserDefaults.standard.data(forKey: candidateKey)
        .flatMap { try? JSONDecoder().decode([String: [StayPlaceCandidate]].self, from: $0) } ?? [:]

    private static func remember(_ candidates: [StayPlaceCandidate], for key: String) {
        if storedCandidates.count >= cacheLimit { storedCandidates.removeAll(keepingCapacity: true) }
        storedCandidates[key] = candidates
        UserDefaults.standard.set(try? JSONEncoder().encode(storedCandidates), forKey: candidateKey)
    }

    static func names(for points: [GeoPoint]) async -> [String: String] {
        var result: [String: String] = [:]
        var lookups = 0
        for point in points {
            let key = NLEPlaceLane.nameKey(for: point)
            // 국내 자리는 카카오 후보까지 있어야 다 찾은 것이다(SPC1114A01: 이름만 기억한 자리도 한 번 더 본다).
            let korea = MapHomeKakaoSearch.isAvailable(at: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
            if let cached = cache[key], !korea || storedCandidates[key] != nil {
                result[key] = cached
                continue
            }
            guard lookups < maximumLookups, !Task.isCancelled else { continue }
            lookups += 1
            guard let name = await nearestName(to: point, key: key) else { continue }
            if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[key] = name
            result[key] = name
        }
        if lookups > 0 { UserDefaults.standard.set(cache, forKey: storageKey) }
        return result
    }

    private static func nearestName(to point: GeoPoint, key: String) async -> String? {
        let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
        let location = CLLocation(latitude: point.latitude, longitude: point.longitude)
        // 국내는 카카오 장소를 먼저 본다(대표 결정 2026-11-13: Apple 지도가 가게 대신 건물 이름을 줬음).
        // 분류를 넓혀 1층 카페가 병원·학교를 덮지 않게 가장 가까운 곳을 고른다.
        if MapHomeKakaoSearch.isAvailable(at: center), let found = await MapHomeKakaoSearch.stayCandidates(at: center), let first = found.first {
            remember(found, for: key)
            return first.name
        }
        let request = MKLocalPointsOfInterestRequest(center: center, radius: searchRadiusMeters)
        if let response = try? await MKLocalSearch(request: request).start() {
            let nearest = response.mapItems
                .filter { !($0.name ?? "").isEmpty }
                .min {
                    location.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude, longitude: $0.placemark.coordinate.longitude))
                        < location.distance(from: CLLocation(latitude: $1.placemark.coordinate.latitude, longitude: $1.placemark.coordinate.longitude))
                }
            if let name = nearest?.name { return name }
        }
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name ?? placemark?.subLocality ?? placemark?.locality
    }
}

/// 이름 없는 「머무름」 기록에 찾은 장소 이름을 붙인다(KKP1113A01, 대표 결정: 기록 이름에도).
/// 자동 기록만 바꾸고, 사용자가 고친 기록은 그대로 둔다. 이름을 못 찾으면 「머무름」으로 남는다.
enum StayPlaceNaming {
    static let evidence = "장소 이름(지도 검색)"
    static let minimumMinutes = 10.0

    static func retitling(
        _ actuals: [ActualRecord],
        places: [PlaceStay],
        names: [String: String],
        candidates: [String: [StayPlaceCandidate]] = [:],
        activityCorrections: [UUID: ActivityCorrection] = [:],
        calendar: Calendar = .autoupdatingCurrent,
        asOf now: Date
    ) -> [ActualRecord] {
        guard !names.isEmpty || !candidates.isEmpty else { return actuals }
        let unknown = StationaryContextKind.unknownStay
        return actuals.map { actual in
            let span = actual.span(asOf: now)
            let ours = actual.evidence.contains(evidence)
            // 결제로 확정한 곳은 건드리지 않는다(PAY1114A01).
            guard !actual.evidence.contains(where: { $0.hasPrefix(PaymentStayAnchor.evidencePrefix) }),
                  actual.behavior == unknown.rawValue && actual.title == unknown.title || ours,
                  span.duration >= minimumMinutes * 60,
                  !ActualRecord.userOwned(actual, activityCorrections: activityCorrections),
                  let point = places.first(where: { $0.point != nil && $0.span.overlapsMostly(span) })?.point else { return actual }
            let key = NLEPlaceLane.nameKey(for: point)
            let list = candidates[key] ?? []
            let mealStay = isMealStay(span, calendar: calendar)
            let picked = StayPlaceCandidate.choose(list, mealStay: mealStay)
            guard let name = picked?.name ?? names[key] else { return actual }
            var value = actual
            value.evidence.removeAll { $0 == evidence || $0.hasPrefix(candidatePrefix) }
            value.evidence.append(evidence)
            if list.count > 1 { value.evidence.append(candidatePrefix + list.prefix(5).map(\.name).joined(separator: "·")) }
            // 식사 시간에 식당에 오래 머물렀으면 식사다(SPC1114A01, 대표 「식당이면 밥 먹었을 거 아니야」).
            if mealStay, picked?.isMeal == true {
                value.title = "식사 · " + name
                value.categoryID = "eating"
                value.behavior = "meal"
            } else {
                value.title = name
                value.categoryID = unknown.categoryID
                value.behavior = unknown.rawValue
            }
            return value == actual ? actual : value
        }
    }

    static let candidatePrefix = "근처 후보: "

    /// 점심(11~14시)·저녁(17~21시)에 시작해 30분 넘게 머문 곳.
    static func isMealStay(_ span: TimeSpan, calendar: Calendar) -> Bool {
        let hour = calendar.component(.hour, from: span.start)
        return span.duration >= 30 * 60 && ((11..<14).contains(hour) || (17..<21).contains(hour))
    }

    /// 이름이 필요한 「머무름」 자리(오래 머문 곳부터, 이미 기억한 곳은 뺀다).
    static func pointsNeedingNames(_ actuals: [ActualRecord], places: [PlaceStay], known: [String: String], asOf now: Date) -> [GeoPoint] {
        let unknown = StationaryContextKind.unknownStay.rawValue
        var seen = Set<String>()
        return actuals
            .filter { ($0.behavior == unknown || $0.evidence.contains(evidence)) && $0.span(asOf: now).duration >= minimumMinutes * 60 }
            .sorted { $0.span(asOf: now).duration > $1.span(asOf: now).duration }
            .compactMap { actual in places.first { $0.point != nil && $0.span.overlapsMostly(actual.span(asOf: now)) }?.point }
            .filter { known[NLEPlaceLane.nameKey(for: $0)] == nil && seen.insert(NLEPlaceLane.nameKey(for: $0)).inserted }
    }
}
/// 카카오가 준 머문 곳 가게 후보(SPC1114A01).
struct StayPlaceCandidate: Codable, Equatable, Sendable {
    var name: String
    /// 카카오 분류 코드(FD6 음식점, CE7 카페 …).
    var code: String
    /// 「음식점 > 뷔페」처럼 나눈 분류 이름.
    var category: String
    var meters: Double

    /// 끼니가 되는 식당(간식·디저트·제과는 빼고).
    var isMeal: Bool { code == "FD6" && !category.contains("간식") }

    /// 식사 시간에 오래 머문 곳이면 가까운 식당을, 아니면 가장 가까운 곳.
    static func choose(_ candidates: [StayPlaceCandidate], mealStay: Bool) -> StayPlaceCandidate? {
        let byDistance = candidates.sorted { $0.meters < $1.meters }
        if mealStay, let meal = byDistance.first(where: \.isMeal) { return meal }
        return byDistance.first
    }
}

/// 결제 시각으로 머문 곳과 활동을 확정한다(PAY1114A01, 대표 지시 2026-11-14 「영수증 지출 내역이랑 시간이랑 비교해서 머무른 장소 확정…
/// 대분류가 바뀐 경우에는 반영」). 결제는 그 시각 그 가게에 있었다는 가장 강한 근거다.
/// ① 이름 없는 체류(또는 지도 검색으로 이름 붙인 체류) 안의 결제 → 그 가게와 활동으로 확정.
/// ② 「집에서 휴식」 안의 결제인데 앞뒤 10분 안에 걸은 기록이 있으면(집 반경 안의 가게) → 그 시간만 떼어 외출 기록으로.
/// 온라인·정기 결제를 막으려고 ①은 근처 후보가 있으면 이름이 맞아야 하고, ②는 걸은 흔적이 있어야 한다.
/// 사용자가 고친 기록은 건드리지 않고, 다시 돌려도 결과가 같다(떼어 낸 기록 번호는 결제 번호에서 만든다).
enum PaymentStayAnchor {
    struct Payment: Equatable, Sendable {
        var id: UUID
        var time: Date
        var merchant: String
        var category: LedgerCategory
    }

    static let evidencePrefix = "결제 확인: "
    static let modelVersion = "classifier-v1/payment"
    /// 결제 앞 이만큼을 그 가게에 있던 시간으로 본다(첫 결제는 15분, 이어진 결제는 앞 결제 뒤부터).
    static let leadSeconds: TimeInterval = 15 * 60
    static let tailSeconds: TimeInterval = 2 * 60
    static let walkWindow: TimeInterval = 10 * 60

    /// 가계부 기록에서 쓸 결제만: 지출·취소 안 됨·교통·급여·여행·숙박·선물 제외.
    static func payments(_ entries: [LedgerEntry], in span: TimeSpan) -> [Payment] {
        entries.filter {
            $0.kind == .expense && $0.canceledAt == nil && span.contains($0.occurredAt)
                && ![.transport, .salary, .travel, .lodging, .gift].contains($0.category)
                && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
        }
        .map { Payment(id: $0.id, time: $0.occurredAt, merchant: $0.title, category: $0.category) }
        .sorted { $0.time < $1.time }
    }

    struct Label: Equatable {
        var title: String
        var categoryID: String
        var behavior: String
    }

    static let healthWords = ["의원", "병원", "의학과", "치과", "한의원", "약국", "정형외과", "내과", "안과", "피부과", "이비인후과", "소아과", "클리닉"]

    /// 가게 종류 → 활동. 가계부 분류가 「기타」여도 이름에 의원·약국이 있으면 건강이다.
    static func label(_ payment: Payment) -> Label {
        let stay = StationaryContextKind.unknownStay.rawValue
        if payment.category == .health || healthWords.contains(where: payment.merchant.contains) {
            return Label(title: "병원·약국 · " + payment.merchant, categoryID: "health", behavior: stay)
        }
        switch payment.category {
        case .food: return Label(title: "식사 · " + payment.merchant, categoryID: "eating", behavior: "meal")
        case .cafe: return Label(title: "카페 · " + payment.merchant, categoryID: "rest", behavior: StationaryContextKind.cafe.rawValue)
        case .shopping, .living: return Label(title: "장보기 · " + payment.merchant, categoryID: "routine", behavior: stay)
        case .culture: return Label(title: payment.merchant, categoryID: "hobby", behavior: stay)
        case .education: return Label(title: payment.merchant, categoryID: "study", behavior: stay)
        default: return Label(title: payment.merchant, categoryID: "activity", behavior: stay)
        }
    }

    /// 결제 가게 이름과 지도 후보 이름이 같은 가게인지(공백·지점 이름을 빼고 앞 두 글자 이상이 겹치는지).
    static func matches(_ merchant: String, _ candidate: String) -> Bool {
        func core(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "").lowercased() }
        let a = core(merchant), b = core(candidate)
        guard a.count >= 2, b.count >= 2 else { return false }
        return a.contains(b.prefix(min(4, b.count))) || b.contains(a.prefix(min(4, a.count)))
    }

    static func recordID(_ payment: UUID, _ salt: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data((payment.uuidString + salt).utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    static func applying(
        _ actuals: [ActualRecord],
        payments: [Payment],
        places: [PlaceStay],
        candidates: [String: [StayPlaceCandidate]],
        activityCorrections: [UUID: ActivityCorrection] = [:],
        asOf now: Date
    ) -> [ActualRecord] {
        // 전에 떼어 낸 외출 기록 가운데 그 안에 결제가 더는 없는 것(지운 결제)은 없앤다.
        func isOuting(_ actual: ActualRecord) -> Bool { actual.modelVersion == modelVersion }
        var result = actuals.filter { actual in
            guard isOuting(actual) else { return true }
            let span = actual.span(asOf: now)
            return payments.contains { span.contains($0.time) || $0.time == span.end }
        }
        guard !payments.isEmpty else { return result }
        func owned(_ actual: ActualRecord) -> Bool { ActualRecord.userOwned(actual, activityCorrections: activityCorrections) }
        let unknown = StationaryContextKind.unknownStay.rawValue
        let home = StationaryContextKind.homeRest.rawValue
        var previousEnd: Date?
        for payment in payments {
            let label = label(payment)
            let mark = evidencePrefix + payment.merchant
            let end = payment.time.addingTimeInterval(tailSeconds)
            // 이미 떼어 낸 외출 안의 결제: 같은 가게면 그 방문을 늘리고(진료비·수납), 집 기록이 다시 만들어졌으면 다시 자른다.
            if let index = result.firstIndex(where: { isOuting($0) && $0.span(asOf: now).contains(payment.time) }) {
                if result[index].evidence.first == mark, let old = result[index].endedAt, old < end { result[index].endedAt = end }
                let visit = result[index].span(asOf: now)
                previousEnd = visit.end
                result = cutting(result, window: visit, payment: payment.id, owned: owned, asOf: now)
                continue
            }
            // ① 이름 없는 체류 안의 결제.
            func isOpenStay(_ actual: ActualRecord) -> Bool {
                guard !owned(actual), !isOuting(actual), actual.source == .location, actual.span(asOf: now).contains(payment.time) else { return false }
                if actual.behavior == unknown { return true }
                return actual.behavior == "meal" && actual.evidence.contains(StayPlaceNaming.evidence)
            }
            if let index = result.firstIndex(where: isOpenStay) {
                let span = result[index].span(asOf: now)
                let nearby = places.first { $0.point != nil && $0.span.overlapsMostly(span) }?.point.flatMap { candidates[NLEPlaceLane.nameKey(for: $0)] } ?? []
                guard nearby.isEmpty || nearby.contains(where: { matches(payment.merchant, $0.name) }) else { continue }
                result[index].title = label.title
                result[index].categoryID = label.categoryID
                result[index].behavior = label.behavior
                result[index].evidence.removeAll { $0.hasPrefix(evidencePrefix) }
                result[index].evidence.append(mark)
                continue
            }
            // ② 「집에서 휴식」 안의 결제 + 걸은 흔적. 바로 앞 결제에 이어진 것이면(20분 안) 이미 집 기록을 잘라 냈으므로 이어서 본다.
            var continues = false
            if let previousEnd { continues = payment.time.timeIntervalSince(previousEnd) <= 20 * 60 }
            func isHome(_ actual: ActualRecord) -> Bool { !owned(actual) && actual.behavior == home && actual.span(asOf: now).contains(payment.time) }
            func isWalk(_ actual: ActualRecord) -> Bool { actual.behavior == "walking" && abs(actual.startedAt.timeIntervalSince(payment.time)) <= walkWindow }
            guard continues || result.contains(where: isHome), result.contains(where: isWalk) else { continue }
            var start = payment.time.addingTimeInterval(-leadSeconds)
            if let previousEnd, previousEnd > start { start = min(previousEnd, payment.time) }
            previousEnd = end
            result = cutting(result, window: TimeSpan(start: start, end: end), payment: payment.id, owned: owned, asOf: now)
            result.append(ActualRecord(
                id: recordID(payment.id, "stay"), planID: nil, title: label.title, categoryID: label.categoryID,
                startedAt: start, endedAt: end, source: .location, confidence: .high, createdAt: start,
                behavior: label.behavior, evidence: [mark, "집 반경 안 외출"], modelVersion: modelVersion
            ))
        }
        return result.sorted { $0.startedAt < $1.startedAt }
    }

    /// 그 시간에 걸친 「집에서 휴식」·「집안일」 자동 기록을 잘라 낸다.
    private static func cutting(
        _ actuals: [ActualRecord], window: TimeSpan, payment: UUID, owned: (ActualRecord) -> Bool, asOf now: Date
    ) -> [ActualRecord] {
        let cuttable: Set<String> = [StationaryContextKind.homeRest.rawValue, StationaryContextKind.housework.rawValue]
        var result: [ActualRecord] = []
        for actual in actuals {
            let span = actual.span(asOf: now)
            guard !owned(actual), let behavior = actual.behavior, cuttable.contains(behavior),
                  span.start < window.end, window.start < span.end else { result.append(actual); continue }
            if span.start < window.start {
                var before = actual
                before.endedAt = window.start
                result.append(before)
            }
            if window.end < span.end {
                var after = actual
                if span.start < window.start { after.id = recordID(payment, "after-" + actual.id.uuidString) }
                after.startedAt = window.end
                result.append(after)
            }
        }
        // 다시 돌릴 때 같은 번호의 뒤 조각이 겹치지 않게 한다.
        var seen = Set<UUID>()
        return result.reversed().filter { seen.insert($0.id).inserted }.reversed()
    }
}
