import Foundation

extension AppModel {
    /// 잠금화면·다이나믹 아일랜드에 실어 보낼 '지금 활동'.
    ///
    /// 예전에는 잠금화면용 분류를 `TaptionCurrentActivityPolicy`가 따로 계산했다. 그래서
    /// 앱 화면(시간 레일)이 '업무'라고 보여 주는 동안 잠금화면은 '활동'이나 다른 이름으로
    /// 뜨는 일이 있었다(대표 지적, UXP1024D20 ③). 이제 앱 화면과 **같은 엔진**에서 같은
    /// 이름·같은 대분류를 읽어 두 화면이 어긋나지 않게 한다.
    ///
    /// 잠금화면에 보이는 이름이 필요 없을 때(잠금 상태)는 nil을 주고, 부르는 쪽이 기존
    /// '확인 중' 표시로 물러선다.
    func liveActivityCurrentProjection(
        at date: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> (title: String, categoryID: String, systemImage: String, startedAt: Date)? {
        guard !TaptionExternalPrivacyStore.isLocked else { return nil }
        let dayStart = calendar.startOfDay(for: date)
        let segments = MapHomeTimeRailSegmentEngine.segments(
            from: snapshot.actuals,
            travel: snapshot.travel,
            on: dayStart,
            asOf: date,
            calendar: calendar
        )
        let minute = min(1_439, max(0, Int(date.timeIntervalSince(dayStart) / 60)))
        guard let segment = MapHomeTimeRailSegmentEngine.segment(at: minute, in: segments),
              segment.categoryID != "unconfirmed" else { return nil }
        let systemImage = RecordClassificationCatalog.categories.first {
            $0.id == segment.categoryID
        }?.systemImage
            ?? TimelineRowKind(categoryID: segment.categoryID)?.systemImage
            ?? "sparkles"
        let startedAt = calendar.date(
            byAdding: .minute,
            value: segment.startMinute,
            to: dayStart
        ) ?? date
        return (segment.title, segment.categoryID, systemImage, startedAt)
    }
}
