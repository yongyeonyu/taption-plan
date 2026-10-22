import SwiftUI

/// 지도 왼쪽 상단의 일정 버튼. 구글 캘린더(구글 계정이 추가된 기기 캘린더) 아이콘이다.
struct MapHomeCalendarButton: View {
    let isExpanded: Bool
    /// 오늘 일정 개수. 0보다 크면 오른쪽 위에 숫자로 표시한다(메모 버튼과 같은 모양).
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

/// 오늘 일정 목록. 권한이 없으면 요청 버튼을, 있으면 오늘(자정~다음 자정) 일정을 시간순으로 보여 준다.
struct MapHomeTodayCalendarList: View {
    let language: MapHomeLanguage
    let service: AppleCalendarService

    @State private var state: LoadState = .loading

    private enum LoadState: Equatable {
        case loading
        case needsPermission
        case denied
        case failed
        case loaded([CalendarRecord])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.text("오늘 일정", "Today"))
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
                Text(language.text("오늘 일정이 없어요.", "No events today."))
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
        .task { await load() }
    }

    private func timeText(_ event: CalendarRecord) -> String {
        if event.isAllDay { return language.text("종일", "All day") }
        return event.span.start.formatted(date: .omitted, time: .shortened)
    }

    @MainActor
    private func load() async {
        if GoogleCalendarAccount.shared.isConnected {
            do {
                state = .loaded(try await GoogleCalendarAccount.shared.todayEvents())
            } catch {
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
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
            let events = await service.events(in: TimeSpan(start: start, end: end), selectedCalendarIDs: [])
            state = .loaded((events ?? []).sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.span.start < rhs.span.start
            })
        }
    }
}
