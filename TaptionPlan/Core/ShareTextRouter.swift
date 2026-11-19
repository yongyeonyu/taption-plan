import Foundation
import TaptionPlanStore

/// 공유로 받은 글이 항공 알림이 아닐 때의 길(FLT1119A01 확장). 순서:
/// ① 기기 안에서 날짜·시각을 모두 읽을 수 있으면 일정으로 넣는다(여행 기간이면 그 여행 일정으로, 아니면 하루 일정으로).
/// ② 못 읽으면 연결된 AI에게 맡긴다(`notification_review`: 서버·AI 안내가 이미 「다른 앱에서 온 글을 일정이나 메모로, 아니면 무시」로 다룬다).
///    글의 카드번호 같은 민감한 숫자는 큐가 가려서 올린다. AI 연결이 꺼져 있으면 보내지 않는다.
/// ③ AI도 없으면 메모로 남겨 글이 사라지지 않게 한다.
extension AppModel {
    @MainActor
    func routeSharedText(_ text: String, now: Date, calendar: Calendar = .autoupdatingCurrent) async -> FlightIngest.Reply {
        let language = MapHomeLanguage.current
        if let draft = ShareScheduleParser.parse(text, now: now, calendar: calendar), await addSharedSchedule(draft, original: text, calendar: calendar, language: language) {
            return .planAdded
        }
        let received = ISO8601DateFormatter().string(from: now)
        if AITaskQueue.enqueue(.notificationReview, text: text, day: now, context: ["sourceApp": "share", "receivedAt": received]) {
            return .sentToAI
        }
        if await saveSharedMemo(text, at: now) { return .savedAsMemo }
        return .deferred
    }

    /// 일정 하나를 넣는다. 그 날짜를 덮는 여행이 있으면 여행 일정으로, 없으면 하루 일정(AI 비서의 일정 더하기와 같은 길)으로.
    @MainActor
    private func addSharedSchedule(_ draft: ShareScheduleParser.Draft, original: String, calendar: Calendar, language: MapHomeLanguage) async -> Bool {
        let title = draft.title.isEmpty ? language.text("공유한 일정", "Shared plan") : draft.title
        let end = draft.start.addingTimeInterval(Double(draft.durationMinutes) * 60)
        let note = Self.cleanTripNote(String(original.prefix(500))) ?? ""
        let dayKey = TravelTripDay.string(for: draft.start, offsetSeconds: calendar.timeZone.secondsFromGMT(for: draft.start))
        if let trip = FlightIngest.trip(on: dayKey, in: snapshot.settings.travelTrips ?? []) {
            let zone = trip.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
            let kind = draft.kind.flatMap(TripImportItem.Kind.init(rawValue:)) ?? .other
            return await addTripItem(tripID: trip.id, kind: kind, title: title, start: draft.start, end: end, offsetSeconds: zone.secondsFromGMT(for: draft.start), note: note) != nil
        }
        let result = await applyAssistantAction(.addSchedule(title: title, start: draft.start, end: end, note: note.isEmpty ? nil : note, extras: AssistantScheduleExtras()))
        return result.reason == nil
    }

    /// 메모로 남긴다. 메모 한도(1,000자)를 넘으면 잘라 넣는다.
    @MainActor
    private func saveSharedMemo(_ text: String, at: Date) async -> Bool {
        let result = await applyAssistantAction(.addMemo(text: String(text.prefix(1_000)), at: at))
        return result.reason == nil
    }
}
