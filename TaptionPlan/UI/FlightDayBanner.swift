import SwiftUI
import TaptionPlanStore

/// 출발 당일 여행 모드 상단 배너(FLT1119A01). 지연·결항, 터미널, 탑승구, 수하물 수취대와 「정기 스케줄 기준 / 실시간」을 보인다.
/// 인천 출·도착편은 열릴 때 공공데이터 운항현황을 한 번 받아 덮어 보인다(받지 못하면 저장된 값과 정기 스케줄 기준 그대로).
struct FlightDayBanner: View {
    let items: [TravelTripItem]
    let language: MapHomeLanguage

    @State private var live: [String: FlightListing] = [:]

    var body: some View {
        let rows = FlightDayBoard.rows(items: items, live: live, now: .now)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "airplane.departure")
                    Text(language.text("오늘의 항공편", "Today's flights")).font(.caption.weight(.semibold))
                    Spacer()
                    Text(rows.contains(where: \.isLive) ? language.text("실시간", "Live") : language.text("정기 스케줄 기준", "Scheduled timetable"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in line(row) }
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("flightDayBanner")
            .task(id: rows.map(\.id)) { await refresh() }
        } else {
            Color.clear.frame(height: 0)
        }
    }

    private func line(_ row: FlightDayRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(row.timeText).font(.callout.monospacedDigit().weight(.semibold)).strikethrough(row.isCancelled)
                Text(row.title).font(.callout)
                Spacer(minLength: 0)
                if row.isCancelled {
                    Text(language.text("결항", "Cancelled")).font(.caption.weight(.semibold)).foregroundStyle(.red)
                } else if row.delayMinutes > 0 {
                    Text(language.runtimeText("\(row.delayMinutes)분 지연", "Delayed \(row.delayMinutes) min")).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                }
            }
            HStack(spacing: 10) {
                if let terminal = row.terminal { Text(language.runtimeText("터미널 \(terminal)", "Terminal \(terminal)")) }
                if let gate = row.gate { Text(language.runtimeText("탑승구 \(gate)", "Gate \(gate)")) }
                if let baggage = row.baggage { Text(language.runtimeText("수하물 \(baggage)", "Baggage \(baggage)")) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 운항현황을 받는다. 서버 주소·키가 없거나 막히면 조용히 넘어간다(오류 화면 없음).
    private func refresh() async {
        var next: [String: FlightListing] = [:]
        for ask in FlightDayBoard.lookups(items: items, now: .now) {
            guard case .found(let result) = await FlightLookup.fetch(.status, airport: "ICN", day: ask.day, direction: ask.direction, flight: ask.flight),
                  let row = result.flights.first(where: { $0.flight == ask.flight && $0.status != nil }) else { continue }
            next[ask.flight] = row
        }
        if next != live { live = next }
    }
}
