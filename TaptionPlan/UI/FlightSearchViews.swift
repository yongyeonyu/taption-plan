import SwiftUI

/// 항공편 찾기 화면의 부품(FLT1120A01): 공항 검색 시트·날짜 스트립·결과 행. 기존 토큰(코너·회색·파랑)만 쓴다.

/// 최근 쓴 공항 코드(최대 4개). 코드만 기기에 저장하고 서버로 보내지 않는다.
enum FlightRecentAirports {
    static let key = "flightRecentAirports"
    static let limit = 4

    static func codes(_ raw: String) -> [String] { raw.split(separator: ",").map(String.init).filter { !$0.isEmpty } }

    static func adding(_ code: String, to raw: String) -> String {
        let next = [code.uppercased()] + codes(raw).filter { $0 != code.uppercased() }
        return next.prefix(limit).joined(separator: ",")
    }
}

struct FlightAirportSheet: View {
    let language: MapHomeLanguage
    let title: String
    /// 목록 범위: nil이면 전 세계, 있으면 그 코드만(국내선·한국 쪽 고르기).
    let allowed: Set<String>?
    var onPick: (FlightPlacement.AirportChoice) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FlightRecentAirports.key) private var recent = ""
    @State private var query = ""

    private var matches: [FlightPlacement.AirportChoice] {
        let text = query.trimmingCharacters(in: .whitespaces)
        let base = text.isEmpty ? FlightPlacement.koreanAirports : FlightPlacement.searchAirports(text, limit: 30)
        return allowed.map { codes in base.filter { codes.contains($0.code) } } ?? base
    }

    private var recents: [FlightPlacement.AirportChoice] {
        FlightRecentAirports.codes(recent).compactMap { code in
            FlightPlacement.searchAirports(code, limit: 1).first { $0.code == code }
        }.filter { allowed?.contains($0.code) ?? true }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, !recents.isEmpty {
                    Section(language.text("최근", "Recent")) { ForEach(recents) { row($0) } }
                }
                Section { ForEach(matches) { row($0) } }
            }
            .searchable(text: $query, prompt: language.text("코드·도시 이름", "Code or city"))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
        }
        .accessibilityIdentifier("flightAirportSearch")
    }

    private func row(_ airport: FlightPlacement.AirportChoice) -> some View {
        Button {
            recent = FlightRecentAirports.adding(airport.code, to: recent)
            onPick(airport)
            dismiss()
        } label: {
            HStack {
                Text(airport.code).font(.body.monospaced().weight(.semibold)).frame(width: 48, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(language.runtimeText(airport.nameKo, airport.nameEn))
                    Text(airport.nameEn).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .foregroundStyle(.primary)
    }
}

/// 어제 ~ +7일 아홉 칸. 여행 첫날·마지막 날이 범위 안이면 점을 찍는다.
struct FlightDateStrip: View {
    let language: MapHomeLanguage
    let days: [String]
    @Binding var selected: String
    let marked: Set<String>

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        Button { selected = day } label: {
                            VStack(spacing: 2) {
                                Text(Self.weekday(day, language: language)).font(.caption2)
                                Text(String(day.suffix(2))).font(.body.monospacedDigit().weight(.semibold))
                                Circle().fill(marked.contains(day) ? Color.tpReferenceBlue : .clear).frame(width: 4, height: 4)
                            }
                            .frame(minWidth: 44, minHeight: 52)
                            .background(selected == day ? Color.tpReferenceBlue.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: TaptionCorner.small))
                            .overlay(RoundedRectangle(cornerRadius: TaptionCorner.small).stroke(selected == day ? Color.tpReferenceBlue : Color.tpReferenceGray.opacity(0.25)))
                        }
                        .buttonStyle(.plain)
                        .id(day)
                        .accessibilityLabel(day)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
        }
        .accessibilityIdentifier("flightDateStrip")
    }

    private static func weekday(_ day: String, language: MapHomeLanguage) -> String {
        guard let parts = TravelTripDay.components(day) else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let date = calendar.date(from: parts) else { return "" }
        let index = calendar.component(.weekday, from: date) - 1
        let ko = ["일", "월", "화", "수", "목", "금", "토"], en = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return language.runtimeText(ko[index], en[index])
    }
}

/// 곧은 선 끝에 작은 원(직항). 비행선 그림은 `Shape`로 그린다.
struct FlightRouteLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.midY))
        path.addEllipse(in: CGRect(x: rect.maxX - 6, y: rect.midY - 3, width: 6, height: 6))
        return path
    }
}

struct FlightResultRow: View {
    let language: MapHomeLanguage
    let row: FlightSearch.Row

    private var durationText: String {
        guard let total = row.durationMinutes else { return "" }
        let (h, m) = FlightSearch.hoursAndMinutes(total)
        return h > 0 ? language.runtimeText("\(h)시간 \(m)분", "\(h)h \(m)m") : language.runtimeText("\(m)분", "\(m)m")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(FlightSearch.clockText(row.departureMinute)).font(.title3.monospacedDigit().weight(.semibold))
                    Text(row.listing.origin).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    Text(durationText).font(.caption2).foregroundStyle(.secondary)
                    FlightRouteLine().stroke(Color.tpReferenceGray, lineWidth: 1).frame(height: 8)
                    Text(language.text("직항", "Direct")).font(.caption2.weight(.semibold)).foregroundStyle(Color.tpReferenceBlue)
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 2) {
                        Text(FlightSearch.clockText(row.arrivalMinute)).font(.title3.monospacedDigit().weight(.semibold))
                        if row.arrivalDayOffset > 0 { Text("+\(row.arrivalDayOffset)").font(.caption2.weight(.bold)).foregroundStyle(.orange) }
                    }
                    Text(row.listing.destination).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text(row.listing.flight).font(.caption.monospaced())
                Text(row.listing.airline).font(.caption).foregroundStyle(.secondary)
                if row.isEstimated { Text(language.text("도착 어림", "Estimated")).font(.caption2).foregroundStyle(.tertiary) }
                if let status = row.listing.status, status.isProblem {
                    Text(status.state == "cancelled" ? language.text("결항", "Cancelled") : language.runtimeText("\(status.delayMinutes)분 지연", "Delayed \(status.delayMinutes) min"))
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("flightRow-\(row.listing.flight)")
    }
}
