import CryptoKit
import Foundation
import TaptionPlanStore

/// 출발이 가까운 비행을 화랑이 말풍선으로 알린다(FLT1119A01). 기존 말풍선 길(`AssistantBubbleStore`, 종류 event)을 그대로 쓴다.
/// 출발 4시간 전부터 출발 때까지(그날 안), 지연 글을 받았으면 지연 문구로 바꾼다. 서버·AI를 거치지 않고 기기 안에서만 만든다.
/// 말풍선 id는 일정 칸마다 정해져 있어(같은 일정은 같은 id) 다시 맞출 때 겹쳐 쌓이지 않는다.
enum FlightBubble {
    static let leadHours = 4
    /// 이만큼 앞서서부터 말풍선을 준비한다(그 전에는 창이 아직 시작하지 않아 보이지 않는다).
    static let horizon: TimeInterval = 48 * 3_600

    /// 일정 칸마다 정해진 말풍선 id.
    static func id(tripID: String, itemID: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data("flight-bubble|\(tripID)|\(itemID)".utf8)).prefix(16))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    /// 지금 이후 출발하는 비행마다 말풍선 하나. 창은 출발 4시간 전(그날 0시보다 앞서지 않게)부터 출발까지.
    static func bubbles(items: [TravelTripItem], now: Date, calendar: Calendar = .autoupdatingCurrent, language: MapHomeLanguage = .current) -> [AssistantBubble] {
        items.filter { $0.isFlight && $0.start > now && $0.start < now.addingTimeInterval(horizon) }.sorted { $0.start < $1.start }.compactMap { item in
            let windowStart = max(item.start.addingTimeInterval(-Double(leadHours) * 3_600), calendar.startOfDay(for: item.start))
            guard now < item.start, let text = speech(for: item, language: language), AssistantBubbleText(text) != nil else { return nil }
            return AssistantBubble(id: id(tripID: item.tripID, itemID: item.itemID), start: windowStart, end: item.start, text: text, kind: .event, createdAt: nil)
        }
    }

    static func speech(for item: TravelTripItem, language: MapHomeLanguage) -> String? {
        let delay = FlightCardMapping.card(from: item)?.currentDelayMinutes ?? 0
        let local = clock(item.start, offset: item.startOffsetSeconds)
        if delay > 0 {
            let name = item.flightNumber ?? [item.originCode, item.destinationCode].compactMap { $0 }.joined(separator: "→")
            return language.runtimeText("\(name) \(delay)분 지연, 새 출발 \(local)", "\(name) delayed \(delay) min, new departure \(local)")
        }
        guard let arrive = FlightBriefingPolicy.arriveBy(item) else { return nil }
        let by = clock(arrive, offset: item.startOffsetSeconds)
        return language.runtimeText("곧 출발! 공항에 \(by)까지 가요 ✈", "Departing soon! Be at the airport by \(by) ✈")
    }

    private static func clock(_ date: Date, offset: Int) -> String {
        let local = Int(date.timeIntervalSince1970) + offset
        let minute = ((local % 86_400) + 86_400) % 86_400 / 60
        return String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    /// 말풍선 파일을 지금 일정에 맞춘다. 바뀐 것이 없으면 쓰지 않는다.
    @MainActor
    static func sync(items: [TravelTripItem], now: Date = .now, calendar: Calendar = .autoupdatingCurrent, language: MapHomeLanguage = .current,
                     file: URL = AssistantBubbleStore.url) {
        let mine = Set(items.filter(\.isFlight).map { id(tripID: $0.tripID, itemID: $0.itemID) })
        let all = AssistantBubbleStore.load(from: file)
        let current = all.filter { mine.contains($0.id) }
        let desired = bubbles(items: items, now: now, calendar: calendar, language: language)
        func same(_ a: [AssistantBubble], _ b: [AssistantBubble]) -> Bool {
            a.sorted { $0.id.uuidString < $1.id.uuidString }.map { [$0.id.uuidString, $0.text, "\($0.start.timeIntervalSince1970)", "\($0.end.timeIntervalSince1970)", $0.hidden ? "h" : ""] }
                == b.sorted { $0.id.uuidString < $1.id.uuidString }.map { [$0.id.uuidString, $0.text, "\($0.start.timeIntervalSince1970)", "\($0.end.timeIntervalSince1970)", $0.hidden ? "h" : ""] }
        }
        // 사용자가 숨긴 말풍선은 다시 켜지 않는다.
        let hidden = Set(current.filter(\.hidden).map(\.id))
        let wanted = desired.filter { !hidden.contains($0.id) } + current.filter(\.hidden)
        guard !same(current, wanted) else { return }
        AssistantBubbleStore.save(all.filter { !mine.contains($0.id) } + wanted, to: file)
    }
}
