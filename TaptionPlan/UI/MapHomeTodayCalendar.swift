import SwiftUI

/// 일정을 읽지 못한 이유. 구글 연결 실패는 앱 설정, 기기 캘린더 권한 꺼짐은 iOS 설정에서 고친다.
enum MapHomeCalendarAccessProblem: Equatable {
    case googleFailed
    case permissionDenied
}

/// 그날 일정을 읽는다. 구글을 직접 연결했으면 구글, 아니면 기기 캘린더다.
enum MapHomeDayCalendarLoader {
    /// 날짜나 구글 연결 상태가 바뀌면 일정을 다시 읽는다.
    @MainActor
    static func key(day: Date) -> String {
        "\(day.timeIntervalSinceReferenceDate)-\(GoogleCalendarAccount.shared.isConnected)"
    }

    @MainActor
    static func events(
        on day: Date,
        calendar: Calendar,
        service: AppleCalendarService
    ) async -> ([CalendarRecord], MapHomeCalendarAccessProblem?) {
        if GoogleCalendarAccount.shared.isConnected {
            do {
                return (try await GoogleCalendarAccount.shared.events(on: day, calendar: calendar), nil)
            } catch {
                return ([], .googleFailed)
            }
        }
        let permission = service.permissionState()
        if [.denied, .unavailable].contains(permission) { return ([], .permissionDenied) }
        guard permission == .authorized else { return ([], nil) }
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return (await service.events(in: TimeSpan(start: start, end: end), selectedCalendarIDs: []) ?? [], nil)
    }
}

enum MapHomeCalendarTitleChoice: Equatable {
    case automatic
    case none
    case detail(String)
}

/// 일정 제목의 상세활동을 보여 주고 고치는 메뉴. 대분류 아래 상세활동 2단계다(CAL1103A01).
struct MapHomeCalendarTitleMenu: View {
    let title: String
    let stored: [String: CalendarTitleDetail]
    let language: MapHomeLanguage
    let onChoose: (MapHomeCalendarTitleChoice) -> Void

    private var verdict: CalendarTitleClassification.Verdict? {
        CalendarTitleClassification.verdict(for: title, stored: stored)
    }

    private var label: String {
        guard let verdict else { return language.text("분류 없음", "No category") }
        guard let id = verdict.detailID,
              let pair = CalendarTitleClassification.selectableCategories.lazy.compactMap({ category in
                  category.details.first { $0.id == id }.map { (category, $0) }
              }).first else { return language.text("분류 안 함", "Not categorized") }
        let origin = switch verdict.origin {
        case .user: language.text("직접", "You")
        case .rule: language.text("자동", "Auto")
        }
        return "\(pair.0.localizedTitle(language)) - \(pair.1.localizedTitle(language)) · \(origin)"
    }

    var body: some View {
        Menu {
            Button(language.text("자동으로 판정", "Automatic")) { onChoose(.automatic) }
            Button(language.text("분류 안 함", "Don't categorize")) { onChoose(.none) }
            ForEach(CalendarTitleClassification.selectableCategories) { category in
                Menu(category.localizedTitle(language)) {
                    ForEach(category.details) { detail in
                        Button(detail.localizedTitle(language)) { onChoose(.detail(detail.id)) }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
            .foregroundStyle(Color.tpReferenceBlue)
        }
        .accessibilityLabel(Text("\(title) \(language.text("상세활동", "activity")): \(label)"))
    }
}

/// 왼쪽 상단의 일정 버튼. 구글 캘린더(구글 계정이 추가된 기기 캘린더) 아이콘이다.
struct MapHomeCalendarButton: View {
    let isExpanded: Bool
    /// 선택한 날 일정 개수. 0보다 크면 오른쪽 위에 숫자로 표시한다(메모 버튼과 같은 모양).
    var count: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MapHomeCalendarSourceLogo()
                .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
                .padding(10)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.tpReferenceBlue, in: Capsule())
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "calendar.circle.fill")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(13))))
                        .foregroundStyle(Color.tpSecondary)
                        .background(Color.white, in: Circle())
                        .overlay { Circle().strokeBorder(Color.tpBorder, lineWidth: TaptionBorder.width) }
                        .offset(x: 2, y: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Google Calendar"))
    }
}

/// 고른 날짜의 일정 목록. 권한이 없으면 요청 버튼을, 있으면 그날(자정~다음 자정) 일정을
/// 시간순으로 보여 준다. 날짜를 바꾸면 그 날짜의 일정으로 다시 불러온다.
struct MapHomeTodayCalendarList: View {
    let language: MapHomeLanguage
    let service: AppleCalendarService
    /// 이 목록이 보여 줄 날짜. 지도에서 고른 날짜를 그대로 받는다.
    let date: Date
    /// 일정 제목별로 저장한 상세활동과, 사용자가 고쳤을 때 알리는 곳(CAL1103A01).
    var titleDetails: [String: CalendarTitleDetail] = [:]
    var onChooseDetail: (String, MapHomeCalendarTitleChoice) -> Void = { _, _ in }

    @State private var state: LoadState = .loading
    /// 지금 화면에 올라와 있는 목록이 어느 날짜 것인지. 날짜가 바뀌면 곧바로 로딩으로 돌린다.
    @State private var loadedDate: Date?

    private enum LoadState: Equatable {
        case loading
        case needsPermission
        case denied
        case failed
        case loaded([CalendarRecord])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .needsPermission:
                Text(language.text("구글 계정 일정을 보려면 캘린더 접근을 허용해 주세요.", "Allow calendar access to see Google events."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                Button(language.text("캘린더 접근 허용", "Allow calendar access")) {
                    Task {
                        _ = try? await service.requestFullAccess()
                        await load()
                    }
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
            case .failed:
                Text(language.text("구글 캘린더를 불러오지 못했어요. 설정에서 연결을 확인해 주세요.", "Could not load Google Calendar. Check the connection in Settings."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            case .denied:
                Text(language.text("캘린더 접근이 꺼져 있어요. 설정 > 개인정보 보호에서 허용해 주세요.", "Calendar access is off. Enable it in Settings > Privacy."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            case .loaded(let events) where events.isEmpty:
                Text(emptyText)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            case .loaded(let events):
                ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 1) {
                            // 제목 위에 시간을 적어 제목이 길어도 언제인지 바로 보인다.
                            Text(timeText(event))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold))
                                .foregroundStyle(Color.tpAccent)
                            Text(event.title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                                .foregroundStyle(Color.tpInk)
                                .fixedSize(horizontal: false, vertical: true)
                            if let notes = event.notes {
                                Text(notes)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                    .foregroundStyle(Color.tpSecondary)
                                    .lineLimit(6)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !event.isAllDay {
                                MapHomeCalendarTitleMenu(title: event.title, stored: titleDetails, language: language) { choice in
                                    onChooseDetail(event.title, choice)
                                }
                            }
                        }
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: MapHomeDayCalendarLoader.key(day: date)) { await load() }
    }

    /// 오늘이면 "오늘 일정", 다른 날이면 그 날짜를 제목에 적어 어느 날 목록인지 바로 보이게 한다.
    private var title: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return language.text("오늘 일정", "Today") }
        let day = date.formatted(Date.FormatStyle().month().day().locale(language.locale))
        return language.text("\(day) 일정", "Events on \(day)")
    }

    private var emptyText: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return language.text("오늘 일정이 없어요.", "No events today.")
        }
        return language.text("이 날 일정이 없어요.", "No events on this day.")
    }

    private func timeText(_ event: CalendarRecord) -> String {
        if event.isAllDay { return language.text("종일", "All day") }
        let start = event.span.start.formatted(date: .omitted, time: .shortened)
        return "\(start) – \(event.span.end.formatted(date: .omitted, time: .shortened))"
    }

    @MainActor
    private func load() async {
        let calendar = Calendar.autoupdatingCurrent
        let day = date
        // 날짜를 바꾼 직후에는 이전 날짜 목록을 그대로 두지 않는다.
        if let loadedDate, !calendar.isDate(loadedDate, inSameDayAs: day) {
            state = .loading
        }
        if GoogleCalendarAccount.shared.isConnected {
            do {
                let events = try await GoogleCalendarAccount.shared.events(on: day, calendar: calendar)
                // 날짜를 빠르게 넘기면 이전 날짜의 늦은 응답이 올 수 있으므로 지금 날짜와 같을 때만 반영한다.
                guard calendar.isDate(day, inSameDayAs: date) else { return }
                loadedDate = day
                state = .loaded(events)
            } catch {
                guard calendar.isDate(day, inSameDayAs: date) else { return }
                loadedDate = day
                state = .failed
            }
            return
        }
        switch service.permissionState() {
        case .notDetermined:
            state = .needsPermission
        case .denied, .unavailable:
            state = .denied
        case .limited, .authorized:
            let start = calendar.startOfDay(for: day)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            let events = await service.events(in: TimeSpan(start: start, end: end), selectedCalendarIDs: [])
            guard calendar.isDate(day, inSameDayAs: date) else { return }
            loadedDate = day
            state = .loaded((events ?? []).sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.span.start < rhs.span.start
            })
        }
    }
}

/// 일정 출처 로고. 구글 계정을 연결했으면 구글, 아니면 애플 캘린더다.
struct MapHomeCalendarSourceLogo: View {
    var body: some View {
        if GoogleCalendarAccount.shared.isConnected {
            Image("GoogleGLogo").resizable().scaledToFit()
        } else {
            Image(systemName: "applelogo").resizable().scaledToFit().foregroundStyle(Color.black)
        }
    }
}

/// 메뉴 연결의 캘린더 화면. 한 번 눌러 연결하고, 구글이 안 되면 애플 캘린더를 쓴다.
struct MapHomeCalendarConnectSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(language.text("캘린더 연결", "Connect calendar"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(21)), weight: .bold))
                Spacer()
                Button(language.text("닫기", "Close")) { dismiss() }
            }
            Text(language.text("일정을 읽어 지도와 활동 판정에 씁니다. 일정은 기기에만 저장합니다.", "Events are read for the map and activity detection and stay on this device."))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            connectButton(
                GoogleCalendarAccount.shared.isConnected ? language.text("구글 캘린더 연결 해제", "Disconnect Google") : language.text("구글 캘린더 바로 연결", "Connect Google Calendar"),
                logo: AnyView(Image("GoogleGLogo").resizable().scaledToFit()), action: toggleGoogle
            )
            connectButton(
                language.text("애플 캘린더 사용", "Use Apple Calendar"),
                logo: AnyView(Image(systemName: "applelogo").resizable().scaledToFit().foregroundStyle(Color.tpInk)), action: useApple
            )
            if let message {
                Text(message)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    .foregroundStyle(Color.tpAccent)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Color.tpBackground)
        .presentationDetents([.medium])
    }

    private func connectButton(_ title: String, logo: AnyView, action: @escaping () async -> Void) -> some View {
        Button {
            guard !isWorking else { return }
            isWorking = true
            Task { await action(); isWorking = false }
        } label: {
            HStack(spacing: 12) {
                logo.frame(width: 22, height: 22)
                Text(title).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold)).foregroundStyle(Color.tpInk)
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isWorking)
    }

    private func toggleGoogle() async {
        if GoogleCalendarAccount.shared.isConnected {
            await model.disconnectGoogleCalendar()
            message = language.text("구글 연결을 해제했습니다.", "Google disconnected.")
            return
        }
        do {
            try await GoogleCalendarAccount.shared.connect()
            message = language.text("구글 캘린더를 연결했습니다.", "Google Calendar connected.")
        } catch GoogleCalendarError.cancelled {
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    private func useApple() async {
        let granted = await model.requestCalendar()
        message = granted ? language.text("애플 캘린더를 연결했습니다.", "Apple Calendar connected.")
            : language.text("설정 앱에서 캘린더 권한을 켜 주세요.", "Turn on calendar access in Settings.")
    }
}
