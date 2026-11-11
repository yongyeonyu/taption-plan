import SwiftUI

/// 앱을 열 때 사용자 판단이 필요한 것을 한 번에 하나씩 묻는다(ASK1111A01, 대표 결정).
/// 순서: 위치 「항상 허용」 → 내 차 → 지하철·버스 탑승 확인 → 처음 보는 일정 분류 → 자주 가는 곳 → 미확인 시간.
/// 한 번 연 동안 같은 질문은 다시 묻지 않고, 「나중에」는 다음에 열 때 다시 묻는다.
enum MapHomeLaunchPrompt: Identifiable, Hashable {
    case carAudio(String)
    case boarding(String)
    case calendarTitle(String)
    case frequentPlace(String)
    case unconfirmed(minutes: Int)

    var id: String {
        switch self {
        case .carAudio(let name): "car:\(name)"
        case .boarding(let id): "boarding:\(id)"
        case .calendarTitle(let title): "calendar:\(CalendarTitleClassification.key(title))"
        case .frequentPlace(let id): "place:\(id)"
        case .unconfirmed: "unconfirmed"
        }
    }
}

enum MapHomeLaunchPromptPolicy {
    /// 미확인 시간이 이보다 짧으면 앱을 열 때 묻지 않는다. 사이드바의 「?」로 고칠 수 있다.
    static let minimumUnconfirmedMinutes = 10

    static func next(
        carAudio: String?,
        boardingIDs: [String],
        calendarTitles: [String],
        placeSuggestionID: String?,
        unconfirmedMinutes: Int,
        asked: Set<String>
    ) -> MapHomeLaunchPrompt? {
        var queue: [MapHomeLaunchPrompt] = []
        if let carAudio { queue.append(.carAudio(carAudio)) }
        queue += boardingIDs.map(MapHomeLaunchPrompt.boarding)
        queue += calendarTitles.map(MapHomeLaunchPrompt.calendarTitle)
        if let placeSuggestionID { queue.append(.frequentPlace(placeSuggestionID)) }
        if unconfirmedMinutes >= minimumUnconfirmedMinutes { queue.append(.unconfirmed(minutes: unconfirmedMinutes)) }
        return queue.first { !asked.contains($0.id) }
    }

    /// 오늘·어제 일정 가운데 분류를 아직 정하지 않은 제목. 종일·취소 일정은 묻지 않는다.
    static func unansweredCalendarTitles(
        _ events: [CalendarRecord],
        stored: [String: CalendarTitleDetail],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String] {
        let today = calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        var seen = Set<String>(), result: [String] = []
        for event in events.sorted(by: { $0.span.start < $1.span.start })
        where !event.isAllDay && event.isCancelled != true && event.span.start >= from && event.span.start < now {
            let key = CalendarTitleClassification.key(event.title)
            guard !key.isEmpty, stored[key] == nil, seen.insert(key).inserted else { continue }
            result.append(event.title)
        }
        return result
    }
}

extension MapHomeView {
    /// 앱이 앞으로 올 때마다 돈다. 앞 질문이 닫혀야 다음을 묻는다.
    func runLaunchPrompts() async {
        await checkLocationAlways()
        while !Task.isCancelled, scenePhase == .active {
            while isLocationAlwaysPromptPresented || launchPrompt != nil
                || selectedTransitBoardingCandidate != nil || isUnconfirmedReviewPresented {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            await model.registerConnectedCarPlay()
            model.refreshFrequentPlaceSuggestion()
            let isToday = Calendar.autoupdatingCurrent.isDateInToday(model.selectedDate)
            let unconfirmed = isToday
                ? MapHomeUnconfirmedReviewPolicy.segments(from: timeRailSegments, for: model.selectedDate)
                    .reduce(0) { $0 + $1.endMinute - $1.startMinute }
                : 0
            guard let next = MapHomeLaunchPromptPolicy.next(
                carAudio: model.pendingCarAudioSuggestion,
                boardingIDs: isToday ? transitBoardingCandidates.map(\.id) : [],
                calendarTitles: MapHomeLaunchPromptPolicy.unansweredCalendarTitles(
                    model.snapshot.calendarEvents, stored: model.settings.calendarTitleDetails
                ),
                placeSuggestionID: model.frequentPlaceSuggestion?.id,
                unconfirmedMinutes: unconfirmed,
                asked: launchPromptsAsked
            ) else { return }
            launchPromptsAsked.insert(next.id)
            if case .boarding(let id) = next {
                selectedTransitBoardingCandidate = transitBoardingCandidates.first { $0.id == id }
            } else {
                launchPrompt = next
            }
        }
    }
}

extension View {
    func mapHomeLaunchPrompts(
        _ prompt: Binding<MapHomeLaunchPrompt?>,
        model: AppModel,
        language: MapHomeLanguage,
        onReviewUnconfirmed: @escaping () -> Void
    ) -> some View {
        modifier(MapHomeLaunchPromptAlerts(prompt: prompt, model: model, language: language, onReviewUnconfirmed: onReviewUnconfirmed))
    }
}

private struct MapHomeLaunchPromptAlerts: ViewModifier {
    @Binding var prompt: MapHomeLaunchPrompt?
    let model: AppModel
    let language: MapHomeLanguage
    let onReviewUnconfirmed: () -> Void

    private func isShowing(_ match: @escaping (MapHomeLaunchPrompt) -> Bool) -> Binding<Bool> {
        Binding(get: { prompt.map(match) ?? false }, set: { if !$0 { prompt = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(language.text("이 기기가 내 차 같아요", "This looks like your car"), isPresented: isShowing { if case .carAudio = $0 { true } else { false } }, presenting: carName) { name in
                Button(language.text("내 차로 등록", "Register as my car")) { Task { await model.setCarAudio(name, isMyCar: true) } }
                Button(language.text("아니요", "No"), role: .cancel) { Task { await model.setCarAudio(name, isMyCar: false) } }
            } message: { name in
                Text(language.text(
                    "‘\(name)’ 기기가 탈 때만 연결됐어요. 등록할까요? 등록하면 이 기기가 연결된 이동을 자동차로 기록해요.",
                    "‘\(name)’ connected only while you rode. Register it? Trips with it connected will be recorded as car."
                ))
            }
            .confirmationDialog(calendarDialogTitle, isPresented: isShowing { if case .calendarTitle = $0 { true } else { false } }, titleVisibility: .visible, presenting: calendarTitle) { title in
                ForEach(calendarChoices(for: title), id: \.id) { choice in
                    Button(choice.label) { Task { await model.setCalendarTitleDetail(choice.id, title: title, on: model.selectedDate) } }
                }
                Button(language.text("분류 안 함", "Don't classify")) { Task { await model.setCalendarTitleDetail(nil, title: title, on: model.selectedDate) } }
                Button(language.text("나중에", "Later"), role: .cancel) {}
            } message: { _ in
                Text(language.text("한 번 정하면 같은 제목의 일정은 다시 묻지 않아요.", "Once set, events with the same title won't be asked again."))
            }
            .confirmationDialog(language.text("자주 머무는 곳이 있어요", "You stay here often"), isPresented: isShowing { if case .frequentPlace = $0 { true } else { false } }, titleVisibility: .visible) {
                ForEach(FrequentPlaceKind.allCases, id: \.self) { kind in
                    Button(placeKindTitle(kind)) { model.registerFrequentPlaceSuggestion(as: kind) }
                }
                Button(language.text("등록 안 함", "Don't register")) { model.dismissFrequentPlaceSuggestion() }
                Button(language.text("나중에", "Later"), role: .cancel) {}
            } message: {
                Text(placeMessage)
            }
            .alert(language.text("미확인 시간이 있어요", "Some time is unconfirmed"), isPresented: isShowing { if case .unconfirmed = $0 { true } else { false } }, presenting: unconfirmedMinutes) { _ in
                Button(language.text("지금 정하기", "Review now")) { onReviewUnconfirmed() }
                Button(language.text("나중에", "Later"), role: .cancel) {}
            } message: { minutes in
                Text(language.text("오늘 \(minutes)분이 무엇을 했는지 모르는 시간이에요. 지금 정할까요?", "\(minutes) min today are unconfirmed. Review them now?"))
            }
    }

    private var carName: String? { if case .carAudio(let name) = prompt { name } else { nil } }
    private var calendarTitle: String? { if case .calendarTitle(let title) = prompt { title } else { nil } }
    private var unconfirmedMinutes: Int? { if case .unconfirmed(let minutes) = prompt { minutes } else { nil } }

    private var calendarDialogTitle: String {
        language.text("‘\(calendarTitle ?? "")’ 일정은 무엇인가요?", "What is ‘\(calendarTitle ?? "")’?")
    }

    /// 제목 규칙이 고른 상세를 맨 위에 둔다.
    private func calendarChoices(for title: String) -> [(id: String, label: String)] {
        let rule = CalendarTitleClassification.ruleDetailID(for: title)
        let all = CalendarTitleClassification.selectableCategories.flatMap { category in
            category.details.map { (id: $0.id, label: "\(category.localizedTitle(language)) · \($0.localizedTitle(language))") }
        }
        return all.filter { $0.id == rule } + all.filter { $0.id != rule }
    }

    private var placeMessage: String {
        guard let suggestion = model.frequentPlaceSuggestion else { return "" }
        let name = suggestion.suggestedName ?? language.text("이 자리", "This spot")
        return language.text(
            "‘\(name)’에 \(suggestion.visitCount)번 머물렀어요. 어떤 곳인가요?",
            "You stayed at ‘\(name)’ \(suggestion.visitCount) times. What is it?"
        )
    }

    private func placeKindTitle(_ kind: FrequentPlaceKind) -> String {
        switch kind {
        case .home: language.text("집", "Home")
        case .school: language.text("학교", "School")
        case .academy: language.text("학원", "Academy")
        case .company: language.text("회사", "Work")
        case .hobby: language.text("취미", "Hobby")
        case .exercise: language.text("운동", "Exercise")
        case .restaurant: language.text("식당", "Restaurant")
        case .custom: language.text("기타", "Other")
        }
    }
}
