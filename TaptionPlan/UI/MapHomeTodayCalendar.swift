import SwiftUI

/// 왼쪽 상단의 일정 버튼. 구글 캘린더(구글 계정이 추가된 기기 캘린더) 아이콘이다.
struct MapHomeCalendarButton: View {
    let isExpanded: Bool
    /// 선택한 날 일정 개수. 0보다 크면 오른쪽 위에 숫자로 표시한다(메모 버튼과 같은 모양).
    var count: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image("GoogleGLogo")
                .resizable()
                .scaledToFit()
                .padding(10)
                .frame(width: 40, height: 40)
                .mapHomeGlass(in: Circle())
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.tpReferenceBlue, in: Capsule())
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "calendar.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.tpSecondary)
                        .background(Color.white, in: Circle())
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
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .needsPermission:
                Text(language.text("구글 계정 일정을 보려면 캘린더 접근을 허용해 주세요.", "Allow calendar access to see Google events."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                Button(language.text("캘린더 접근 허용", "Allow calendar access")) {
                    Task {
                        _ = try? await service.requestFullAccess()
                        await load()
                    }
                }
                .font(.system(size: 12, weight: .bold, design: .rounded))
            case .failed:
                Text(language.text("구글 캘린더를 불러오지 못했어요. 설정에서 연결을 확인해 주세요.", "Could not load Google Calendar. Check the connection in Settings."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            case .denied:
                Text(language.text("캘린더 접근이 꺼져 있어요. 설정 > 개인정보 보호에서 허용해 주세요.", "Calendar access is off. Enable it in Settings > Privacy."))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            case .loaded(let events) where events.isEmpty:
                Text(emptyText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            case .loaded(let events):
                ForEach(events) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(timeText(event))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.tpSecondary)
                            .frame(width: 52, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color.tpInk)
                                .lineLimit(1)
                            Text(event.calendarTitle)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        .mapHomeGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: date) { await load() }
    }

    /// 오늘이면 "오늘 일정", 다른 날이면 그 날짜를 제목에 적어 어느 날 목록인지 바로 보이게 한다.
    private var title: String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return language.text("오늘 일정", "Today") }
        let day = date.formatted(.dateTime.month().day())
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
        return event.span.start.formatted(date: .omitted, time: .shortened)
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
