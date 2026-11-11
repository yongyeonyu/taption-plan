import SwiftUI

/// 앱을 열 때 사용자 판단이 필요한 것을 한 번에 하나씩 묻는다(ASK1111A01, 대표 결정).
/// 순서: 위치 「항상 허용」 → 내 차 → 지하철·버스 탑승 확인 → 처음 보는 일정 분류 → 자주 가는 곳 → 미확인 시간.
/// 한 번 연 동안 같은 질문은 다시 묻지 않는다. 「나중에 확인」을 누르면 그날은 더 묻지 않고
/// 왼쪽 위에 「확인할 것」 아이콘을 둔다. 아이콘을 누르면 다시 차례로 묻는다(LPR1111A01, 대표 결정).
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

/// 「나중에 확인」을 누른 날을 기기에 적어 둔다. 날이 바뀌면 다시 묻는다.
enum MapHomeLaunchPromptDeferral {
    static let key = "launchPromptsDeferredDay"

    static func dayKey(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func isDeferred(_ stored: String?, now: Date = .now, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        stored == dayKey(now, calendar: calendar)
    }

    static func isDeferred(now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        isDeferred(defaults.string(forKey: key), now: now)
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
        #if DEBUG
        // 일정 분류 질문 모양 확인용(CAT1111A01, Debug 전용).
        if ProcessInfo.processInfo.arguments.contains("-calendarPromptPreview") {
            launchPrompt = .calendarTitle("Invitation: MB ATHOS1.0 주간 회의")
            return
        }
        // 가계부 화면 확인용(UIR1111A01, Debug 전용): 기록이 없으면 보기 몇 줄을 넣고 가계부를 연다. 시뮬레이터에서만 쓴다.
        if ProcessInfo.processInfo.arguments.contains("-ledgerPreview") {
            try? await Task.sleep(for: .seconds(3))
            await LedgerBook.shared.load()
            if LedgerBook.shared.entries.isEmpty {
                let samples: [(String, Double, LedgerCategory, TimeInterval)] = [
                    ("회사 커피숍 라떼", 4_500, .cafe, -3_600), ("점심 국밥", 9_000, .food, -7_200), ("경인고속도로 통행료", 900, .transport, -10_800),
                ]
                for sample in samples {
                    var entry = LedgerEntry(occurredAt: Date.now.addingTimeInterval(sample.3), amount: sample.1, title: sample.0)
                    entry.category = sample.2
                    await LedgerBook.shared.save(entry)
                }
            }
            LedgerPresenter.shared.isPresented = true
            return
        }
        // 데이터 보호 시트 확인용(UIR1111A01, Debug 전용).
        if ProcessInfo.processInfo.arguments.contains("-dataProtectionPreview") {
            try? await Task.sleep(for: .seconds(3))
            isDataProtectionPresented = true
            return
        }
        // 지도 모양 확인용(PLN1111A01, Debug 전용): `-mapStylePreview mapLibrePorcelain`.
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-mapStylePreview"),
           let raw = ProcessInfo.processInfo.arguments.dropFirst(index + 1).first, let style = MapDisplayStyle(rawValue: raw) {
            // 저장된 설정을 다 읽은 뒤에 바꿔야 덮어쓰이지 않는다.
            try? await Task.sleep(for: .seconds(4))
            model.setMapDisplayStyle(style)
            return
        }
        #endif
        await checkLocationAlways()
        while !Task.isCancelled, scenePhase == .active {
            // 「나중에 확인」을 누른 날은 더 묻지 않는다. 왼쪽 위 아이콘으로 다시 열 수 있다.
            if MapHomeLaunchPromptDeferral.isDeferred() { return }
            while isLocationAlwaysPromptPresented || launchPrompt != nil
                || selectedTransitBoardingCandidate != nil || isUnconfirmedReviewPresented {
                try? await Task.sleep(for: .milliseconds(400))
                if Task.isCancelled { return }
            }
            if MapHomeLaunchPromptDeferral.isDeferred() { return }
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
        onResume: @escaping () -> Void = {},
        onReviewUnconfirmed: @escaping () -> Void
    ) -> some View {
        modifier(MapHomeLaunchPromptAlerts(prompt: prompt, model: model, language: language, onResume: onResume, onReviewUnconfirmed: onReviewUnconfirmed))
    }
}

private struct MapHomeLaunchPromptAlerts: ViewModifier {
    @Binding var prompt: MapHomeLaunchPrompt?
    let model: AppModel
    let language: MapHomeLanguage
    let onResume: () -> Void
    let onReviewUnconfirmed: () -> Void
    /// 「나중에 확인」을 누른 날. 오늘이면 질문을 띄우지 않고 아이콘만 보인다.
    @AppStorage(MapHomeLaunchPromptDeferral.key) private var deferredDay = ""
    /// 일정 분류 두 번째 단계에서 고른 대분류(CAT1111A01: 대분류 → 상세 두 단계로 묻는다).
    @State private var calendarCategory: String?
    @State private var isReturningToCategories = false

    private func isShowing(_ match: @escaping (MapHomeLaunchPrompt) -> Bool) -> Binding<Bool> {
        Binding(get: { prompt.map(match) ?? false }, set: { if !$0 { prompt = nil } })
    }

    /// 그날은 더 묻지 않는다.
    private func confirmLater() {
        deferredDay = MapHomeLaunchPromptDeferral.dayKey(.now)
        calendarCategory = nil
        prompt = nil
    }

    private var laterTitle: String { language.text("나중에 확인", "Check later") }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if MapHomeLaunchPromptDeferral.isDeferred(deferredDay) {
                    Button {
                        deferredDay = ""
                        onResume()
                    } label: {
                        Image(systemName: "checklist")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.tpAccent)
                            .frame(width: 34, height: 34)
                            .mapHomeGlass(in: Circle())
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("확인할 것", "Things to check"))
                    .accessibilityIdentifier("launchPrompts.deferred")
                    .padding(.leading, 8)
                    .padding(.top, MapHomeLaunchPromptAlerts.iconTop)
                }
            }
            .alert(language.text("이 기기가 내 차 같아요", "This looks like your car"), isPresented: isShowing { if case .carAudio = $0 { true } else { false } }, presenting: carName) { name in
                Button(language.text("내 차로 등록", "Register as my car")) { Task { await model.setCarAudio(name, isMyCar: true) } }
                Button(language.text("아니요", "No")) { Task { await model.setCarAudio(name, isMyCar: false) } }
                Button(laterTitle, role: .cancel) { confirmLater() }
            } message: { name in
                Text(language.text(
                    "‘\(name)’ 기기가 탈 때만 연결됐어요. 등록할까요? 등록하면 이 기기가 연결된 이동을 자동차로 기록해요.",
                    "‘\(name)’ connected only while you rode. Register it? Trips with it connected will be recorded as car."
                ))
            }
            // 1단계: 대분류. 제목 규칙이 고른 상세가 있으면 맨 위에 한 번에 고르는 추천으로 둔다.
            .confirmationDialog(calendarDialogTitle, isPresented: calendarStepBinding(detail: false), titleVisibility: .visible, presenting: calendarTitle) { title in
                if let rule = calendarRule(for: title) {
                    Button(language.text("추천: \(rule.label)", "Suggested: \(rule.label)")) { saveCalendar(rule.id, title: title) }
                }
                ForEach(calendarCategories(for: title), id: \.id) { category in
                    Button(category.localizedTitle(language)) {
                        if category.details.count == 1, let only = category.details.first {
                            saveCalendar(only.id, title: title)
                        } else {
                            calendarCategory = category.id
                        }
                    }
                }
                Button(language.text("분류 안 함", "Don't classify")) { saveCalendar(nil, title: title) }
                Button(laterTitle, role: .cancel) { confirmLater() }
            } message: { _ in
                Text(language.text("먼저 대분류를 고르세요. 한 번 정하면 같은 제목의 일정은 다시 묻지 않아요.", "Pick a category first. Once set, events with the same title won't be asked again."))
            }
            // 2단계: 고른 대분류 안의 상세.
            .confirmationDialog(calendarDetailTitle, isPresented: calendarStepBinding(detail: true), titleVisibility: .visible, presenting: calendarTitle) { title in
                ForEach(calendarDetails, id: \.id) { detail in
                    Button(detail.localizedTitle(language)) { saveCalendar(detail.id, title: title) }
                }
                Button(language.text("뒤로", "Back")) {
                    isReturningToCategories = true
                    calendarCategory = nil
                }
                Button(laterTitle, role: .cancel) { confirmLater() }
            } message: { title in
                Text(language.text("‘\(title)’", "‘\(title)’"))
            }
            .confirmationDialog(language.text("자주 머무는 곳이 있어요", "You stay here often"), isPresented: isShowing { if case .frequentPlace = $0 { true } else { false } }, titleVisibility: .visible) {
                ForEach(FrequentPlaceKind.allCases, id: \.self) { kind in
                    Button(placeKindTitle(kind)) { model.registerFrequentPlaceSuggestion(as: kind) }
                }
                Button(language.text("등록 안 함", "Don't register")) { model.dismissFrequentPlaceSuggestion() }
                Button(laterTitle, role: .cancel) { confirmLater() }
            } message: {
                Text(placeMessage)
            }
            .alert(language.text("미확인 시간이 있어요", "Some time is unconfirmed"), isPresented: isShowing { if case .unconfirmed = $0 { true } else { false } }, presenting: unconfirmedMinutes) { _ in
                Button(language.text("지금 정하기", "Review now")) { onReviewUnconfirmed() }
                Button(laterTitle, role: .cancel) { confirmLater() }
            } message: { minutes in
                Text(language.text("오늘 \(minutes)분이 무엇을 했는지 모르는 시간이에요. 지금 정할까요?", "\(minutes) min today are unconfirmed. Review them now?"))
            }
    }

    /// 위쪽 둥근 단추 줄 바로 아래.
    static let iconTop: CGFloat = 66

    private var carName: String? { if case .carAudio(let name) = prompt { name } else { nil } }
    private var calendarTitle: String? { if case .calendarTitle(let title) = prompt { title } else { nil } }
    private var unconfirmedMinutes: Int? { if case .unconfirmed(let minutes) = prompt { minutes } else { nil } }

    private var calendarDialogTitle: String {
        language.text("‘\(calendarTitle ?? "")’ 일정은 무엇인가요?", "What is ‘\(calendarTitle ?? "")’?")
    }

    /// 일정 질문 두 단계의 표시. 1단계에서 대분류를 고르면 질문을 닫지 않고 2단계로 넘긴다.
    private func calendarStepBinding(detail: Bool) -> Binding<Bool> {
        Binding(
            get: {
                guard case .calendarTitle = prompt else { return false }
                return (calendarCategory != nil) == detail
            },
            set: { shown in
                guard !shown else { return }
                if isReturningToCategories { isReturningToCategories = false; return }
                // 1단계에서 대분류를 골랐으면 2단계가 이어 뜬다.
                if !detail, calendarCategory != nil { return }
                calendarCategory = nil
                prompt = nil
            }
        )
    }

    private func saveCalendar(_ detailID: String?, title: String) {
        calendarCategory = nil
        Task { await model.setCalendarTitleDetail(detailID, title: title, on: model.selectedDate) }
    }

    private var calendarDetailTitle: String {
        let category = CalendarTitleClassification.selectableCategories.first { $0.id == calendarCategory }
        return language.text("‘\(category?.localizedTitle(language) ?? "")’ 중 무엇인가요?", "Which ‘\(category?.localizedTitle(language) ?? "")’?")
    }

    private var calendarDetails: [RecordClassificationDetail] {
        CalendarTitleClassification.selectableCategories.first { $0.id == calendarCategory }?.details ?? []
    }

    /// 제목 규칙이 고른 상세(있으면 1단계 맨 위 추천).
    private func calendarRule(for title: String) -> (id: String, label: String)? {
        guard let rule = CalendarTitleClassification.ruleDetailID(for: title) else { return nil }
        for category in CalendarTitleClassification.selectableCategories {
            if let detail = category.details.first(where: { $0.id == rule }) {
                return (rule, "\(category.localizedTitle(language)) · \(detail.localizedTitle(language))")
            }
        }
        return nil
    }

    /// 규칙이 고른 상세의 대분류를 맨 위에.
    private func calendarCategories(for title: String) -> [RecordClassificationCategory] {
        let all = CalendarTitleClassification.selectableCategories.filter { !$0.details.isEmpty }
        let ruleCategory = CalendarTitleClassification.ruleDetailID(for: title).flatMap { id in all.first { $0.details.contains { $0.id == id } }?.id }
        return all.filter { $0.id == ruleCategory } + all.filter { $0.id != ruleCategory }
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
