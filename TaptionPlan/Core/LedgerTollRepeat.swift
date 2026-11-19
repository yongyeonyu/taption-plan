import Foundation
import SwiftUI
import TaptionPlanCore

/// 같은 길 통행료 자동 넣기(TOL1111A01, 대표 지시 「돌아온 고속도로 톨비 자동 추가」).
/// 앱은 어느 요금소를 지났는지 모른다. 그래서 통행료 지출이 붙은 자동차 이동(출발→도착)을 배워 두고,
/// 같은 길이나 되돌아오는 길을 차로 다시 가면 같은 통행료를 넣는다. 한 이동에는 한 번만 넣고,
/// 사용자가 지워도 다시 넣지 않는다. 이미 그 무렵 통행료가 있으면 넣지 않는다.
/// 이름 쌍만으로는 다른 고속도로로 간 날을 가리지 못해, 길 모양(약 1km 칸)을 함께 배워 견준다(TOL1118A01).
enum LedgerTollRepeat {
    struct Drive: Equatable {
        var from: String
        var to: String
        var start: Date
        var end: Date
        /// 이동 중 정확한 위치를 지난 칸(`LedgerTollRoute.cells`). 기기에만 둔다. 비면 길을 모른다.
        var cells: Set<String> = []
        /// 이동 중 지난 영업소(TGT1118A01). 기기에만 둔다.
        var passes: [LedgerTollGate.Pass] = []
        /// 카카오 길찾기에 물을 때 쓸 점(처음·끝과 사이 최대 5개, KDR1118A01). 기기 메모리에만 두고 저장하지 않는다.
        var points: [LedgerTollKakao.Point] = []

        var key: String { "\(from)|\(to)|\(Int(start.timeIntervalSince1970 / 60))" }
        /// 요금소를 지났을 법한 때. 할인은 이 시각으로 본다.
        var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }

    struct Rule: Codable, Equatable {
        /// 배운 기록의 금액 그대로.
        var amount: Double
        var currency: String
        var title: String
        var learnedAt: Date
        /// 정가(출퇴근 할인 전, TOL1118A01). 예전 규칙에는 없어 `filled`가 채운다.
        var base: Double?
        /// 배운 길 모양(칸). 예전 규칙이나 위치를 모를 때는 없다.
        var route: [String]?
        /// 출퇴근 할인이 없는 정액 도로(민자 도로 등, TGT1119A01). 없으면 할인을 적용한다.
        var flat: Bool?
    }

    /// 한 출발·도착 쌍에 길별로 두는 규칙 수. 넘으면 가장 오래된 것부터 버린다.
    static let maximumRoutesPerPair = 4

    /// 이 출발→도착의 규칙들. 첫 길은 `출발→도착`, 다른 길은 `출발→도착#<길 첫 칸>`이다(TGT1119A01).
    static func candidates(_ rules: [String: Rule], from: String, to: String) -> [(key: String, rule: Rule)] {
        let base = pair(from, to)
        return rules.filter { $0.key == base || $0.key.hasPrefix(base + "#") }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, rule: $0.value) }
    }

    /// 이 이동에 쓸 규칙. 같은 길 규칙이 있으면 그것, 길을 모르는 규칙뿐이면 위치가 충분할 때 카카오에 맡기려고 nil,
    /// 길이 모두 다르면 nil. 가는 방향 규칙이 없을 때만 되돌아오는 방향을 본다.
    static func choose(_ drive: Drive, rules: [String: Rule]) -> (rule: Rule, reversed: Bool, match: LedgerTollRoute.Match)? {
        for reversed in [false, true] {
            let list = candidates(rules, from: reversed ? drive.to : drive.from, to: reversed ? drive.from : drive.to)
            guard !list.isEmpty else { continue }
            let scored = list.map { (rule: $0.rule, match: LedgerTollRoute.match(drive.cells, $0.rule.route)) }
            if let same = scored.first(where: { $0.match == .same }) { return (same.rule, reversed, .same) }
            // 길을 모르는 규칙은 이 길의 금액이 아닐 수 있다. 위치가 충분하면 카카오 길찾기에 맡긴다.
            if let unknown = scored.first(where: { $0.match == .unknown }), drive.cells.count < LedgerTollRoute.minimumCells {
                return (unknown.rule, reversed, .unknown)
            }
            return nil
        }
        return nil
    }

    /// 앱이 넣을 수 있는 금액(배운 금액 그대로, 또는 정가에 할인·할증을 적용한 것).
    static func ownAmounts(_ rule: Rule, base: (Rule) -> Double, legacyBase: (Rule) -> Double? = { _ in nil }) -> [Double] {
        let rates = [0, 0.2, 0.3, 0.4, 0.5, -0.05]
        return [rule.amount] + ([base(rule)] + [legacyBase(rule)].compactMap { $0 }).flatMap { full in rates.map { LedgerTollDiscount.amount(base: full, rate: $0) } }
    }

    /// 배운 정가. 칸이 비었으면 금액이 정가다(손으로 넣는 통행료는 정가가 대부분).
    static func fullPrice(_ rule: Rule) -> Double { rule.base ?? rule.amount }

    /// TOL1118A01 전의 계산: 배운 시각의 출퇴근 할인으로 되돌린 정가. 그 무렵 넣은 금액을 알아보는 데만 쓴다.
    static func legacyBase(_ rule: Rule, isOffDay: (Date) -> Bool, calendar: Calendar) -> Double {
        LedgerTollDiscount.base(from: rule.amount, rate: LedgerTollDiscount.applied(
            at: rule.learnedAt, vehicle: .standard, isOffDay: isOffDay(rule.learnedAt), calendar: calendar).rate)
    }

    /// 손·AI가 넣은 통행료는 정가로 본다. 결제 문자·영수증은 실제로 낸(할인 든) 금액이라 그 시각 할인으로 정가를 되찾는다.
    static func base(of entry: LedgerEntry, rate: (Date) -> Double) -> Double {
        guard entry.currency == "KRW" else { return entry.amount }
        switch entry.source {
        case .message, .receipt: return LedgerTollDiscount.base(from: entry.amount, rate: rate(entry.occurredAt))
        case .manual, .assistant: return entry.amount
        }
    }

    /// 예전 규칙에 정가를 채운다: 배운 기록이 가계부에 남아 있으면 그 출처로, 없으면 금액을 정가로.
    static func filled(_ rules: [String: Rule], entries: [LedgerEntry], rate: (Date) -> Double) -> [String: Rule] {
        rules.mapValues { rule in
            guard rule.base == nil else { return rule }
            var fixed = rule
            let source = entries.first { isToll($0) && $0.amount == rule.amount && abs($0.occurredAt.timeIntervalSince(rule.learnedAt)) < 1 }
            fixed.base = source.map { base(of: $0, rate: rate) } ?? rule.amount
            return fixed
        }
    }

    /// 통행료가 이 이동 무렵(출발 30분 전 ~ 도착 60분 뒤)에 있으면 그 이동의 통행료로 본다.
    static let before: TimeInterval = 30 * 60
    static let after: TimeInterval = 60 * 60
    /// 도착하고 이만큼 지나야 넣는다(같은 이동이 아직 이어질 수 있다).
    static let settle: TimeInterval = 10 * 60

    static func isToll(_ entry: LedgerEntry) -> Bool {
        guard entry.kind == .expense, entry.transfer == nil, entry.category == .transport else { return false }
        let title = entry.title.lowercased()
        return title.contains("통행료") || title.contains("톨비") || title.contains("toll")
    }

    static func pair(_ from: String, _ to: String) -> String { "\(from)→\(to)" }

    /// 그 무렵 통행료가 있는 이동에서 길별 통행료와 길 모양을 배운다. 늦게 본 것이 이긴다.
    /// 길 모양이 다르면 같은 출발·도착이라도 새 규칙으로 따로 둔다(TGT1119A01).
    /// `unitsKnown`: 영업소 목록을 받아 둔 상태. 도로공사 영업소를 안 지났으면 정액 도로로 본다.
    static func learn(
        drives: [Drive], entries: [LedgerEntry], into rules: [String: Rule], rate: (Date) -> Double = { _ in 0 }, unitsKnown: Bool = false
    ) -> [String: Rule] {
        var result = rules
        for entry in entries.filter(isToll).sorted(by: { $0.occurredAt < $1.occurredAt }) {
            guard let drive = drives.first(where: { covers($0, entry.occurredAt) }) else { continue }
            let key = pair(drive.from, drive.to)
            let route = LedgerTollRoute.stored(drive.cells)
            let note = entry.note ?? ""
            // 지난 톨게이트로 넣은 것은 할인이 든 금액이라 배우지 않는다.
            if LedgerTollGate.notes.contains(where: { note.hasPrefix($0) }) { continue }
            if isAuto(entry) {
                let ours = autoNotes.contains { note.hasPrefix($0) }
                let forward = candidates(result, from: drive.from, to: drive.to)
                let target = forward.isEmpty ? candidates(result, from: drive.to, to: drive.from) : forward
                // 같은 길로 넣은 것을 그대로 남겼으면 모르던 길 모양만 배운다. 금액을 고쳤으면 그 길의 규칙으로 새로 배운다.
                if ours, target.contains(where: { ownAmounts($0.rule, base: fullPrice).contains(entry.amount) }) {
                    if let route, let blank = target.first(where: { $0.rule.route == nil && ownAmounts($0.rule, base: fullPrice).contains(entry.amount) }) {
                        result[blank.key]?.route = route
                    }
                    continue
                }
                // 카카오 길찾기로 넣은 것을 확인해 남겼으면 그 금액(정액)을 이 길의 규칙으로 배운다.
                let kakao = LedgerTollKakao.notes.contains { note.hasPrefix($0) }
                guard ours || kakao else { continue }
                store(Rule(amount: entry.amount, currency: entry.currency, title: entry.title, learnedAt: entry.occurredAt,
                           base: entry.amount, route: route, flat: true), drive: drive, key: key, into: &result)
                continue
            }
            // 위치를 모르는 이동에서 배우면 예전 길 모양을 버린다(길이 바뀌었을 수 있다).
            store(Rule(amount: entry.amount, currency: entry.currency, title: entry.title, learnedAt: entry.occurredAt,
                       base: base(of: entry, rate: rate), route: route, flat: unitsKnown && drive.passes.isEmpty ? true : nil),
                  drive: drive, key: key, into: &result)
        }
        return result
    }

    /// 배운 규칙을 길에 맞는 자리에 둔다: 같은 길이면 갈아 끼우고, 길 모양이 다르면 새 규칙으로 더한다.
    private static func store(_ rule: Rule, drive: Drive, key: String, into result: inout [String: Rule]) {
        guard let route = rule.route else {
            if let known = result[key], known.learnedAt > rule.learnedAt { return }
            result[key] = rule
            return
        }
        let list = candidates(result, from: drive.from, to: drive.to)
        if let same = list.first(where: { LedgerTollRoute.match(drive.cells, $0.rule.route) == .same }) {
            if same.rule.learnedAt <= rule.learnedAt { result[same.key] = rule }
            return
        }
        // 길 모양을 모르던 규칙은 정가가 같을 때만 그 길의 것으로 본다.
        if let blank = list.first(where: { $0.rule.route == nil && fullPrice($0.rule) == fullPrice(rule) }) {
            if blank.rule.learnedAt <= rule.learnedAt { result[blank.key] = rule }
            return
        }
        let newKey = list.isEmpty ? key : "\(key)#\(route.first ?? "")"
        result[newKey] = rule
        let all = candidates(result, from: drive.from, to: drive.to)
        for old in all.sorted(by: { $0.rule.learnedAt < $1.rule.learnedAt }).prefix(max(0, all.count - maximumRoutesPerPair)) {
            result[old.key] = nil
        }
    }

    /// 앱이 넣은 통행료(같은 길·지난 톨게이트). 금액에 할인이 들어 있어 배우지 않는다.
    static func isAuto(_ entry: LedgerEntry) -> Bool {
        (autoNotes + LedgerTollGate.notes + LedgerTollKakao.notes).contains { (entry.note ?? "").hasPrefix($0) }
    }

    /// 넣을 통행료. 같은 길이면 그대로, 되돌아오는 길이면 제목의 출근·퇴근을 바꾼다.
    static func entries(
        drives: [Drive], existing: [LedgerEntry], rules: [String: Rule], handled: Set<String>, now: Date,
        vehicle: LedgerTollDiscount.Vehicle = .standard, isOffDay: (Date) -> Bool = { _ in false },
        calendar: Calendar = .autoupdatingCurrent
    ) -> [(drive: Drive, entry: LedgerEntry, applied: LedgerTollDiscount.Applied, suspicious: Bool)] {
        var tolls = existing.filter(isToll).map(\.occurredAt)
        var result: [(drive: Drive, entry: LedgerEntry, applied: LedgerTollDiscount.Applied, suspicious: Bool)] = []
        func rate(_ date: Date) -> LedgerTollDiscount.Applied {
            LedgerTollDiscount.applied(at: date, vehicle: vehicle, isOffDay: isOffDay(date), calendar: calendar)
        }
        for drive in merged(drives) where !handled.contains(drive.key) && drive.end <= now.addingTimeInterval(-settle) {
            guard !tolls.contains(where: { covers(drive, $0) }) else { continue }
            // 같은 길 규칙이 있을 때만 넣는다. 길이 다르거나, 길 모양을 모르는 규칙은 카카오 길찾기가 이어받는다(TGT1119A01).
            guard let chosen = choose(drive, rules: rules) else { continue }
            let rule = chosen.rule
            let title = chosen.reversed ? reversed(rule.title) : rule.title
            let route = chosen.match
            // 정가에 이 이동 시각의 할인을 적용한다(TOL1112B01·TOL1118A01).
            let base = fullPrice(rule)
            let applied = rule.currency == "KRW" && rule.flat != true ? rate(drive.middle) : LedgerTollDiscount.Applied(rate: 0, reason: .none)
            // 출발과 도착의 할인이 다르면 요금소를 언제 지났는지 몰라 확인을 받는다.
            let suspicious = route == .unknown || (rule.currency == "KRW" && rule.flat != true && rate(drive.start).rate != rate(drive.end).rate)
            var entry = LedgerEntry(occurredAt: drive.end, amount: rule.currency == "KRW" ? LedgerTollDiscount.amount(base: base, rate: applied.rate) : rule.amount, title: title)
            entry.currency = rule.currency
            entry.category = .transport
            result.append((drive, entry, applied, suspicious))
            // 같은 길이 여러 조각으로 잡혀도 한 번만 넣는다(TOL1112A01).
            tolls.append(entry.occurredAt)
        }
        return result
    }

    /// 한 번의 이동이 여러 조각으로 잡히면 하나로 본다: 같은 출발·도착이고 겹치거나 30분 안에 이어지는 것.
    static func merged(_ drives: [Drive]) -> [Drive] {
        var result: [Drive] = []
        for drive in drives.sorted(by: { $0.start < $1.start }) {
            if let index = result.lastIndex(where: { $0.from == drive.from && $0.to == drive.to }),
               drive.start <= result[index].end.addingTimeInterval(before) {
                result[index].end = max(result[index].end, drive.end)
                result[index].cells.formUnion(drive.cells)
                // 조각마다 같은 영업소가 잡히면 더 가까웠던 하나만 둔다.
                for pass in drive.passes {
                    if let same = result[index].passes.firstIndex(where: { $0.code == pass.code }) {
                        if pass.meters < result[index].passes[same].meters { result[index].passes[same] = pass }
                    } else {
                        result[index].passes.append(pass)
                    }
                }
                result[index].passes.sort { $0.at < $1.at }
                result[index].points = LedgerTollKakao.sampled(result[index].points + drive.points)
            } else {
                result.append(drive)
            }
        }
        return result
    }

    /// 자동으로 넣은 통행료를 그 시각의 할인으로 다시 계산한 것. 바꿀 것이 없거나 손으로 고친 금액이면 nil.
    /// 메모는 「자동 추가 · 출발 → 도착 · 할인」 꼴이고, 정가는 그 길(또는 반대 길)의 규칙에서 `base`로 구한다.
    /// `legacyBase`는 예전 계산의 정가로, 그 계산으로 넣은 금액(예: 900원 정가가 1,130원으로 부푼 뒤의 900·570원)도 알아본다.
    static func adjusted(
        _ entry: LedgerEntry, rules: [String: Rule], base: (Rule) -> Double, legacyBase: (Rule) -> Double? = { _ in nil },
        applied: LedgerTollDiscount.Applied, label: String?
    ) -> LedgerEntry? {
        guard isToll(entry), entry.currency == "KRW", let note = entry.note, autoNotes.contains(where: { note.hasPrefix($0) }) else { return nil }
        let parts = note.components(separatedBy: " · ")
        guard parts.count >= 2 else { return nil }
        let ends = parts[1].components(separatedBy: " → ")
        guard ends.count == 2 else { return nil }
        let list = candidates(rules, from: ends[0], to: ends[1]) + candidates(rules, from: ends[1], to: ends[0])
        // 앱이 넣을 수 있는 금액(배운 금액 그대로, 또는 정가에 할인·할증을 적용한 것)일 때만, 그 금액을 낳은 규칙으로 고친다.
        guard let rule = list.map(\.rule).first(where: { $0.currency == "KRW" && ownAmounts($0, base: base, legacyBase: legacyBase).contains(entry.amount) }) else { return nil }
        let full = base(rule)
        let applied = rule.flat == true ? LedgerTollDiscount.Applied(rate: 0, reason: .none) : applied
        let label = rule.flat == true ? nil : label
        var fixed = entry
        fixed.amount = LedgerTollDiscount.amount(base: full, rate: applied.rate)
        fixed.note = (Array(parts.prefix(2)) + [label].compactMap { $0 }).joined(separator: " · ")
        guard fixed.amount != entry.amount || fixed.note != entry.note else { return nil }
        if fixed.amount != entry.amount { fixed.amountKRW = nil }
        return fixed
    }

    static let autoNotes = ["같은 길 통행료 자동 추가", "Same-route toll, added automatically"]

    /// 자동으로 넣은 통행료의 할인을 볼 시각: 그 이동을 알면 가운데, 모르면 넣은 시각(도착).
    static func tollTime(of entry: LedgerEntry, drives: [Drive]) -> Date {
        let ends = (entry.note ?? "").components(separatedBy: " · ").dropFirst().first?.components(separatedBy: " → ")
        let drive = merged(drives).first { drive in
            abs(drive.end.timeIntervalSince(entry.occurredAt)) < 60 && ends.map { $0 == [drive.from, drive.to] } != false
        }
        return drive?.middle ?? entry.occurredAt
    }

    /// 자동으로 넣은 통행료가 같은 이동에 여러 번 들어간 것(TOL1112A01 전의 버그). 가장 이른 하나만 남기고 지울 id.
    static func duplicates(in entries: [LedgerEntry]) -> [UUID] {
        let auto = entries.filter { entry in isToll(entry) && isAuto(entry) }
            .sorted { $0.occurredAt < $1.occurredAt }
        var kept: [LedgerEntry] = []
        var extra: [UUID] = []
        for entry in auto {
            let same = kept.contains {
                $0.title == entry.title && $0.amount == entry.amount && $0.currency == entry.currency && $0.note == entry.note
                    && entry.occurredAt.timeIntervalSince($0.occurredAt) <= before + after
            }
            if same { extra.append(entry.id) } else { kept.append(entry) }
        }
        return extra
    }

    static func reversed(_ title: String) -> String {
        let marker = "\u{0}"
        return title
            .replacingOccurrences(of: "출근", with: marker)
            .replacingOccurrences(of: "퇴근", with: "출근")
            .replacingOccurrences(of: marker, with: "퇴근")
    }

    static func covers(_ drive: Drive, _ date: Date) -> Bool {
        date >= drive.start.addingTimeInterval(-before) && date <= drive.end.addingTimeInterval(after)
    }
}

/// 통행료 길 모양(TOL1118A01). 앱은 요금소 위치를 모르므로, 배운 이동이 지난 칸과 이번 이동이 지난 칸을 견준다.
/// 칸은 위도·경도 0.01도(약 1km)이고 기기의 통행료 규칙에만 둔다. 서버·AI로 보내지 않는다.
enum LedgerTollRoute {
    enum Match: Equatable { case same, different, unknown }

    static let cellDegrees = 0.01
    /// 이만큼 겹치면 같은 길, 이보다 덜 겹치면 다른 길. 그 사이와 칸이 모자라면 모름.
    static let sameShare = 0.7
    static let differentShare = 0.4
    static let minimumCells = 4
    static let maximumStored = 600

    /// 이어진 위치를 따라 지난 칸. 점 사이가 멀면(고속도로에서 띄엄띄엄 잡힌 위치) 사이를 이어 채운다.
    static func cells(along points: [(latitude: Double, longitude: Double)]) -> Set<String> {
        var result = Set<String>()
        for (index, point) in points.enumerated() {
            guard index > 0 else { result.insert(cell(point.latitude, point.longitude)); continue }
            let previous = points[index - 1]
            let span = max(abs(point.latitude - previous.latitude), abs(point.longitude - previous.longitude))
            // 0.5도(약 50km)를 넘게 뛰면 위치가 끊긴 것이라 잇지 않는다.
            let steps = span > 0.5 ? 1 : max(1, Int((span / (cellDegrees * 0.3)).rounded(.up)))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.insert(cell(previous.latitude + (point.latitude - previous.latitude) * t,
                                   previous.longitude + (point.longitude - previous.longitude) * t))
            }
        }
        return result
    }

    static func cell(_ latitude: Double, _ longitude: Double) -> String {
        "\(Int((latitude / cellDegrees).rounded(.down)))_\(Int((longitude / cellDegrees).rounded(.down)))"
    }

    /// 규칙에 남길 꼴. 칸이 모자라면 길을 모르는 것으로 둔다.
    static func stored(_ cells: Set<String>) -> [String]? {
        cells.count >= minimumCells ? Array(cells.sorted().prefix(maximumStored)) : nil
    }

    /// 두 길이 서로 얼마나 겹치는지(이웃 칸까지 같은 칸으로 본다). 둘 중 작은 쪽으로 판단한다.
    static func match(_ cells: Set<String>, _ learned: [String]?) -> Match {
        guard let learned, learned.count >= minimumCells, cells.count >= minimumCells else { return .unknown }
        let known = Set(learned)
        let share = min(covered(cells, by: known), covered(known, by: cells))
        if share >= sameShare { return .same }
        return share < differentShare ? .different : .unknown
    }

    private static func covered(_ cells: Set<String>, by other: Set<String>) -> Double {
        Double(cells.filter { neighbors($0).contains(where: other.contains) }.count) / Double(cells.count)
    }

    private static func neighbors(_ cell: String) -> [String] {
        let parts = cell.split(separator: "_").compactMap { Int($0) }
        guard parts.count == 2 else { return [cell] }
        return (-1...1).flatMap { dy in (-1...1).map { dx in "\(parts[0] + dy)_\(parts[1] + dx)" } }
    }
}

/// 손으로(또는 AI가) 넣은 통행료는 차종 할인 전 금액으로 보고, 그 시각의 출퇴근 할인만 든 것으로 본다. 차종을 고르면 거기에 맞춰 줄인다.
/// 고속도로 통행료 할인(TOL1112B01, 대표 지시 2026-11-12). 한국도로공사 구간·1종·하이패스 기준이고, 한 번에 가장 큰 할인 하나만 적용한다.
/// - 평일(공휴일 제외) 05~07시·20~22시 50%, 07~09시·18~20시 20%. 원래는 요금소 사이 20km 미만에만 주지만 앱은 그 거리를 몰라 시각만 본다.
/// - 경차 50%. 전기·수소차 2025년 40%, 2026년 30%, 2027년 20%, 그 뒤 없음(국토교통부 2024-11-15 발표).
/// - 주말·공휴일 07~21시 5% 할증(할인받는 차는 빼고).
enum LedgerTollDiscount {
    enum Vehicle: String, CaseIterable, Sendable { case standard, compact, electric }
    enum Reason: String, Equatable, Sendable { case none, commuteHalf, commuteFifth, compact, electric, weekend }
    struct Applied: Equatable, Sendable {
        /// 0.5는 50% 할인, -0.05는 5% 할증.
        var rate: Double
        var reason: Reason
    }

    static let vehicleKey = "ledgerTollVehicle"

    static func vehicle(_ defaults: UserDefaults = .standard) -> Vehicle {
        defaults.string(forKey: vehicleKey).flatMap(Vehicle.init) ?? .standard
    }

    static func vehicleRate(_ vehicle: Vehicle, year: Int) -> Double {
        switch vehicle {
        case .standard: 0
        case .compact: 0.5
        case .electric: year <= 2024 ? 0.5 : year == 2025 ? 0.4 : year == 2026 ? 0.3 : year == 2027 ? 0.2 : 0
        }
    }

    static func applied(at date: Date, vehicle: Vehicle, isOffDay: Bool, calendar: Calendar = .autoupdatingCurrent) -> Applied {
        let parts = calendar.dateComponents([.year, .hour], from: date)
        let hour = parts.hour ?? 12
        let own = vehicleRate(vehicle, year: parts.year ?? 2026)
        var best = own > 0 ? Applied(rate: own, reason: vehicle == .compact ? .compact : .electric) : Applied(rate: 0, reason: .none)
        if !isOffDay {
            let commute: Applied? = switch hour {
            case 5, 6, 20, 21: Applied(rate: 0.5, reason: .commuteHalf)
            case 7, 8, 18, 19: Applied(rate: 0.2, reason: .commuteFifth)
            default: nil
            }
            if let commute, commute.rate > best.rate { best = commute }
        } else if best.rate == 0, (7..<21).contains(hour) {
            best = Applied(rate: -0.05, reason: .weekend)
        }
        return best
    }

    /// 10원 단위로 맞춘다.
    static func amount(base: Double, rate: Double) -> Double { (base * (1 - rate) / 10).rounded() * 10 }
    static func base(from amount: Double, rate: Double) -> Double { rate >= 1 ? amount : (amount / (1 - rate) / 10).rounded() * 10 }

    static func label(_ applied: Applied, language: MapHomeLanguage) -> String? {
        switch applied.reason {
        case .none: nil
        case .commuteHalf: language.text("출퇴근 할인 50%", "Commute discount 50%")
        case .commuteFifth: language.text("출퇴근 할인 20%", "Commute discount 20%")
        case .compact: language.text("경차 할인 50%", "Compact car discount 50%")
        case .electric: language.text("전기·수소차 할인", "EV discount") + " \(Int((applied.rate * 100).rounded()))%"
        case .weekend: language.text("주말 할증 5%", "Weekend surcharge 5%")
        }
    }

    static func name(_ vehicle: Vehicle, language: MapHomeLanguage) -> String {
        switch vehicle {
        case .standard: language.text("일반", "Standard")
        case .compact: language.text("경차", "Compact")
        case .electric: language.text("전기·수소차", "EV · hydrogen")
        }
    }
}

/// 앱을 열 때·기록이 바뀐 뒤(5분에 한 번) 오늘과 어제의 자동차 이동을 본다.
@MainActor
enum LedgerTollRepeatRunner {
    static let rulesKey = "ledgerTollRules"
    static let handledKey = "ledgerTollHandledDrives"
    private static var lastRunAt = Date.distantPast
    private static var isRunning = false

    static func run(model: AppModel, defaults: UserDefaults = .standard, now: Date = .now, force: Bool = false) async {
        guard !isRunning, force || now.timeIntervalSince(lastRunAt) >= 5 * 60 else { return }
        isRunning = true
        lastRunAt = now
        defer { isRunning = false }
        let calendar = Calendar.autoupdatingCurrent
        var days: [(drives: [LedgerTollRepeat.Drive], readings: [SensorReading])] = []
        for offset in 0..<2 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
                  let input = await model.assistantActivityInput(for: day, now: now, calendar: calendar),
                  let built = AssistantActivityBuilder.make(input, level: .visits) else { continue }
            let readings = await model.planDayDataSnapshot(for: day, forceReload: false).readings
            days.append((carDrives(built, language: input.language), readings))
        }
        // 영업소 목록은 자동차 이동이 있을 때만 받는다(TGT1118A01). 목록을 통째로 받아 기기에서 견주고, 위치는 보내지 않는다.
        let units = days.contains { !$0.drives.isEmpty } ? await TollUnitStore.units(now: now) : []
        let drives = days.flatMap { day in day.drives.map { withRoute($0, readings: day.readings, units: units) } }
        await LedgerBook.shared.load()
        // 가계부를 못 읽었으면 이미 있는 통행료를 알 수 없으니 넣지 않는다.
        guard LedgerBook.shared.isLoaded else { return }
        for id in LedgerTollRepeat.duplicates(in: LedgerBook.shared.entries) {
            await LedgerBook.shared.delete(id)
            TaptionPlanDiagnosticsLogger.shared.record("ledger_toll_repeat_duplicate_removed", fields: [:])
        }
        let entries = LedgerBook.shared.entries
        let isOffDay = { (date: Date) in MapHomeCalendarDayStyle(date: date, calendar: calendar) != .weekday }
        let vehicle = LedgerTollDiscount.vehicle(defaults)
        // 결제 문자의 통행료는 차종·출퇴근 할인이 든 금액이다.
        let paidRate = { (date: Date) in LedgerTollDiscount.applied(at: date, vehicle: vehicle, isOffDay: isOffDay(date), calendar: calendar).rate }
        let stored = defaults.data(forKey: rulesKey).flatMap { try? JSONDecoder().decode([String: LedgerTollRepeat.Rule].self, from: $0) } ?? [:]
        // 예전 규칙에는 정가가 없어 먼저 채운다(TOL1118A01). 한 번 채우면 저장돼 다시 하지 않는다.
        let filled = LedgerTollRepeat.filled(stored, entries: entries, rate: paidRate)
        let rules = LedgerTollRepeat.learn(drives: drives, entries: entries, into: filled, rate: paidRate, unitsKnown: !units.isEmpty)
        if rules != stored, let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: rulesKey) }
        var handled = defaults.stringArray(forKey: handledKey) ?? []
        let language = MapHomeLanguage.current
        // 이미 자동으로 넣은 통행료를 지금 차종·그 시각의 할인으로 맞춘다(최근 14일, 손으로 고친 금액은 두기).
        // 할인은 새로 넣을 때와 같이 이동 가운데 시각으로 보고, 그 이동을 모르면 넣은 시각으로 본다.
        for entry in entries where now.timeIntervalSince(entry.occurredAt) <= 14 * 86_400 {
            let time = LedgerTollRepeat.tollTime(of: entry, drives: drives)
            let applied = LedgerTollDiscount.applied(at: time, vehicle: vehicle, isOffDay: isOffDay(time), calendar: calendar)
            guard let fixed = LedgerTollRepeat.adjusted(
                entry, rules: rules, base: LedgerTollRepeat.fullPrice,
                legacyBase: { LedgerTollRepeat.legacyBase($0, isOffDay: isOffDay, calendar: calendar) },
                applied: applied, label: LedgerTollDiscount.label(applied, language: language)
            ) else { continue }
            await LedgerBook.shared.save(fixed)
        }
        guard !drives.isEmpty else { return }
        // 지난 톨게이트로 먼저 알아내고, 못 알아낸 이동만 같은 길 방식으로 본다(TGT1118A01).
        let gate = await LedgerTollGateRunner.run(
            drives: drives, existing: entries, handled: Set(handled), now: now,
            vehicle: vehicle, isOffDay: isOffDay, calendar: calendar, language: language
        )
        handled += gate.done
        if !gate.done.isEmpty { defaults.set(Array(handled.suffix(200)), forKey: handledKey) }
        let additions = LedgerTollRepeat.entries(
            drives: drives, existing: entries, rules: rules, handled: Set(handled), now: now,
            vehicle: vehicle, isOffDay: isOffDay, calendar: calendar
        )
        for addition in additions {
            var entry = addition.entry
            entry.note = ([language.text("같은 길 통행료 자동 추가", "Same-route toll, added automatically"),
                           "\(addition.drive.from) → \(addition.drive.to)"]
                + [LedgerTollDiscount.label(addition.applied, language: language)].compactMap { $0 }).joined(separator: " · ")
            // 의심스러우면 넣지 않고 「확인 필요」에 올린다(대표 지시: 앱이 먼저 넣고, 의심스러우면 확인 요청).
            // 영업소는 알지만 요금이 0건이면 배운 금액이 맞는지 몰라 확인을 받는다(TGT1118A01).
            if addition.suspicious || gate.unknownFare.contains(addition.drive.key) { LedgerReviewStore.shared.add(entry, reason: .toll, now: now) } else { await LedgerBook.shared.save(entry) }
            handled.append(addition.drive.key)
            TaptionPlanDiagnosticsLogger.shared.record("ledger_toll_repeat_added", fields: ["amount": String(Int(addition.entry.amount))])
        }
        // 지난 톨게이트도 같은 길도 아니면 카카오 길찾기에 묻는다(KDR1118A01). 결과는 늘 「확인 필요」로.
        let kakao = await LedgerTollKakaoRunner.run(drives: drives, existing: entries, handled: Set(handled), now: now, defaults: defaults, language: language)
        handled += kakao
        if !additions.isEmpty || !kakao.isEmpty { defaults.set(Array(handled.suffix(200)), forKey: handledKey) }
    }

    /// 출발·도착 이름을 아는 자동차 이동만. 이름 모르는 「머문 곳」은 길로 보지 않는다.
    static func carDrives(_ day: AssistantActivityDay, language: MapHomeLanguage) -> [LedgerTollRepeat.Drive] {
        let unnamed: Set<String> = [language.text("머문 곳", "Place"), "머문 곳", "Place"]
        return (day.moves ?? []).compactMap { move in
            guard move.mode == "car", let from = move.from, let to = move.to, from != to,
                  !unnamed.contains(from), !unnamed.contains(to),
                  let start = parser.date(from: move.start), let end = parser.date(from: move.end) else { return nil }
            return LedgerTollRepeat.Drive(from: from, to: to, start: start, end: end)
        }
    }

    /// 이동 동안의 정확한 위치(대략 위치·오차 100m 넘는 것은 뺌)로 길 모양을 붙인다. 위치는 기기 밖으로 나가지 않는다.
    /// 지난 영업소도 같은 위치로 본다(TGT1118A01).
    static func withRoute(_ drive: LedgerTollRepeat.Drive, readings: [SensorReading], units: [TollUnit] = []) -> LedgerTollRepeat.Drive {
        let fixes = readings
            .filter { $0.timestamp >= drive.start && $0.timestamp <= drive.end && $0.locationFixQuality != .approximate }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { reading -> LedgerTollGate.Fix? in
                guard let point = reading.point, point.horizontalAccuracy >= 0, point.horizontalAccuracy <= 100 else { return nil }
                return LedgerTollGate.Fix(at: reading.timestamp, latitude: point.latitude, longitude: point.longitude, accuracy: point.horizontalAccuracy)
            }
        var routed = drive
        routed.cells = LedgerTollRoute.cells(along: fixes.map { ($0.latitude, $0.longitude) })
        routed.passes = units.isEmpty ? [] : LedgerTollGate.passes(units: units, fixes: fixes)
        routed.points = LedgerTollKakao.sampled(fixes.map { LedgerTollKakao.Point(at: $0.at, latitude: $0.latitude, longitude: $0.longitude) })
        return routed
    }

    private static var parser: DateFormatter { AssistantActivityBuilder.Stamp.instantParser }
}

/// 지도 화면에 붙는 보이지 않는 관찰자. 앱을 열 때·앞으로 올 때·기록이 바뀔 때 통행료를 본다.
struct LedgerTollRepeatObserver: View {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task { await runAll() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await runAll() } }
            }
            .onChange(of: model.rawDayRevisionSignal) { _, _ in Task { await runAll() } }
    }

    /// 통행료와 버스·지하철 요금(TRF1113A01)을 차례로 본다.
    private func runAll() async {
        await LedgerTollRepeatRunner.run(model: model)
        // 예전에 은행 이름으로 들어간 이체·입금을 상대 이름으로(TPY1115A01).
        await LedgerTransferRename.run()
        // 승하차 지점이 정류장인지 먼저 물어 두면 다음 분류 갱신에서 버스로 바뀌고, 그 뒤 요금이 들어간다(BST1113A01).
        await BusStopLookupRunner.run(model: model)
        RideLineTasks.enqueue(model.snapshot.travel)
        await LedgerTransitFareRunner.run(model: model)
    }
}
