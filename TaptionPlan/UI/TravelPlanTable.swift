import SwiftUI
import TaptionPlanStore

// MARK: - 계획표(TVD1112A01)

/// 계획표 하루치: 분류 열에 놓인 계획 칸, 그 옆에 나란히 보일 실제 기록, 지금 시각.
struct TravelPlanTableModel: Equatable {
    /// 열 순서: 이동 · 식사 · 관광 · 숙소.
    static let columnCount = 4

    struct Block: Identifiable, Equatable {
        let id: String
        var column: Int
        var startMinute: Int
        var endMinute: Int
        var title: String
        var tripStatus: TripItemStatus?
        var status: TravelPlanComparison.Status
    }

    struct Actual: Identifiable, Equatable {
        let id: String
        var startMinute: Int
        var endMinute: Int
        var title: String
        var isMove: Bool
        /// 계획에 없던 머묾.
        var isUnplanned: Bool
    }

    var blocks: [Block]
    var actuals: [Actual]
    /// 그날이 오늘일 때만 있다.
    var nowMinute: Int?

    /// 처음 보여 줄 시각: 오늘이면 지금 한 시간 전, 아니면 첫 일정 30분 전.
    var focusMinute: Int {
        if let nowMinute { return max(0, nowMinute - 60) }
        return max(0, (blocks.map(\.startMinute).min() ?? 9 * 60) - 30)
    }

    static func column(forKind kind: String) -> Int {
        switch kind {
        case "flight", "transfer": 0
        case "meal", "cafe": 1
        case "lodging", "sleep", "rest": 3
        default: 2
        }
    }

    /// `day`는 기기 달력의 그날. 일정은 그곳 벽시계 시각에 놓는다(시간 막대와 같은 규칙).
    static func make(
        items: [TravelTripItem], tripID: String, day: Date, actual: [MapHomeTimeRailSegment], now: Date, calendar: Calendar = .autoupdatingCurrent
    ) -> TravelPlanTableModel {
        var blocks: [Block] = []
        var spans: [TravelPlanComparison.Span] = []
        for item in items where item.tripID == tripID {
            guard let segment = TravelTripRail.segments([item], day: day, calendar: calendar).first else { continue }
            let column = column(forKind: item.kind)
            blocks.append(Block(
                id: item.itemID, column: column, startMinute: segment.startMinute, endMinute: segment.endMinute, title: item.title,
                tripStatus: segment.tripStatus, status: .pending
            ))
            spans.append(.init(id: item.itemID, start: segment.startMinute, end: segment.endMinute, isMove: column == 0))
        }
        var nowMinute: Int?
        let limit: Int
        if calendar.isDate(day, inSameDayAs: now) {
            let parts = calendar.dateComponents([.hour, .minute], from: now)
            nowMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            limit = nowMinute ?? 0
        } else {
            limit = day < now ? 1_440 : 0
        }
        let records = actual.filter { $0.categoryID != "unconfirmed" && $0.endMinute > $0.startMinute }
        let result = TravelPlanComparison.compare(
            plan: spans,
            actual: records.map { .init(id: $0.id, start: $0.startMinute, end: $0.endMinute, isMove: $0.categoryID == "movement") },
            nowMinute: limit
        )
        for index in blocks.indices { blocks[index].status = result.statuses[blocks[index].id] ?? .pending }
        let unplanned = Set(result.unplanned)
        return TravelPlanTableModel(
            blocks: blocks.sorted { ($0.startMinute, $0.id) < ($1.startMinute, $1.id) },
            actuals: records.map {
                Actual(id: $0.id, startMinute: $0.startMinute, endMinute: $0.endMinute, title: $0.title, isMove: $0.categoryID == "movement", isUnplanned: unplanned.contains($0.id))
            },
            nowMinute: nowMinute
        )
    }
}

/// 여행의 날짜들(`YYYY-MM-DD`)과 기기 달력의 그날.
enum TravelPlanDays {
    static func days(of trip: TravelTrip, calendar: Calendar = .autoupdatingCurrent) -> [(key: String, date: Date)] {
        guard let first = TravelTripDay.components(trip.startDay).flatMap(calendar.date(from:)),
              let count = TravelTripDay.days(from: trip.startDay, to: trip.endDay), count >= 0 else { return [] }
        return (0...min(count, 60)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return (TravelTripDay.string(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1), date)
        }
    }
}

/// 계획표: 이동·식사·관광·숙소 열에 계획 칸을 놓고, 시간축 옆에 실제 기록을 나란히 둔다.
struct TravelPlanTable: View {
    let table: TravelPlanTableModel
    let language: MapHomeLanguage
    let onSelect: (TravelPlanTableModel.Block) -> Void

    private let minuteHeight: CGFloat = 0.9
    private let axisWidth: CGFloat = 38
    private let actualWidth: CGFloat = 12

    private var titles: [String] {
        [language.text("이동", "Move"), language.text("식사", "Meals"), language.text("관광", "Sights"), language.text("숙소", "Stay")]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(language.text("실제", "Actual")).font(.caption2).frame(width: axisWidth + actualWidth, alignment: .trailing)
                ForEach(titles.indices, id: \.self) { index in
                    Text(titles[index]).font(.caption.weight(.semibold)).frame(maxWidth: .infinity)
                }
            }
            .foregroundStyle(TravelInk.plan.opacity(0.8))
            .padding(.vertical, 6)
            Divider().overlay(TravelInk.border)
            ScrollViewReader { reader in
                ScrollView { dayBody }
                    .onAppear { reader.scrollTo(table.focusMinute / 60, anchor: .top) }
            }
        }
    }

    /// 하루 전체(0~24시)를 그린 본문. 스크롤 없이도 그릴 수 있게 따로 둔다.
    var dayBody: some View {
        GeometryReader { proxy in
            let columnWidth = (proxy.size.width - axisWidth - actualWidth) / CGFloat(TravelPlanTableModel.columnCount)
            ZStack(alignment: .topLeading) {
                grid(width: proxy.size.width)
                ForEach(table.actuals) { record in actualBar(record, columnWidth: columnWidth) }
                ForEach(table.blocks) { block in planBlock(block, columnWidth: columnWidth) }
                if let now = table.nowMinute {
                    Rectangle().fill(TravelInk.actual).frame(width: proxy.size.width, height: 1.5).offset(y: CGFloat(now) * minuteHeight)
                }
                // 스크롤 자리 표시(한 시간마다).
                ForEach(0..<24, id: \.self) { hour in
                    Color.clear.frame(width: 1, height: 1).offset(y: CGFloat(hour * 60) * minuteHeight).id(hour)
                }
            }
        }
        .frame(height: 1_440 * minuteHeight)
    }

    private func grid(width: CGFloat) -> some View {
        Canvas { context, size in
            for hour in 0...24 {
                let y = CGFloat(hour * 60) * minuteHeight
                var line = Path()
                line.move(to: CGPoint(x: axisWidth, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(TravelInk.border.opacity(0.7)), lineWidth: 0.5)
                guard hour < 24 else { continue }
                context.draw(
                    Text(String(format: "%02d", hour)).font(.system(size: 11)).foregroundStyle(TravelInk.plan.opacity(0.7)),
                    at: CGPoint(x: axisWidth - 6, y: y + 8), anchor: .trailing
                )
            }
        }
        .frame(width: width, height: 1_440 * minuteHeight)
    }

    /// 실제 기록: 시간축 바로 옆의 주홍 띠. 계획에 없던 머묾은 이름을 관광 열에 점선 칸으로 보인다.
    @ViewBuilder
    private func actualBar(_ record: TravelPlanTableModel.Actual, columnWidth: CGFloat) -> some View {
        let height = max(2, CGFloat(record.endMinute - record.startMinute) * minuteHeight)
        RoundedRectangle(cornerRadius: 2)
            .fill(TravelInk.actual.opacity(record.isMove ? 0.45 : 0.9))
            .frame(width: actualWidth - 4, height: height)
            .offset(x: axisWidth + 2, y: CGFloat(record.startMinute) * minuteHeight)
        if record.isUnplanned {
            Text(record.title.isEmpty ? language.text("계획에 없던 방문", "Unplanned stop") : record.title)
                .font(.caption2).lineLimit(2).foregroundStyle(TravelInk.actual)
                .padding(3)
                .frame(width: columnWidth - 4, height: max(18, height), alignment: .topLeading)
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(TravelInk.actual, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                .offset(x: axisWidth + actualWidth + columnWidth * 2 + 2, y: CGFloat(record.startMinute) * minuteHeight)
                .accessibilityLabel(language.text("계획에 없던 방문", "Unplanned stop"))
        }
    }

    private func planBlock(_ block: TravelPlanTableModel.Block, columnWidth: CGFloat) -> some View {
        let height = max(18, CGFloat(block.endMinute - block.startMinute) * minuteHeight)
        let missed = block.status == .skipped
        return Button { onSelect(block) } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 2) {
                    if block.status == .done { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                    if block.status == .late { Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9)).foregroundStyle(TravelInk.actual) }
                    Text(block.title).font(.caption2.weight(.semibold)).lineLimit(height > 30 ? 2 : 1)
                }
                if height > 34 {
                    Text(String(format: "%02d:%02d", block.startMinute / 60, block.startMinute % 60)).font(.system(size: 10)).opacity(0.75)
                }
            }
            .padding(3)
            .frame(width: columnWidth - 4, height: height, alignment: .topLeading)
            .background(TravelInk.planTint.opacity(block.tripStatus == .tentative ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).stroke(
                    missed ? TravelInk.actual : TravelInk.plan,
                    style: StrokeStyle(lineWidth: block.tripStatus == .booked || missed ? 1.5 : 1, dash: block.tripStatus == .tentative ? [3, 3] : [])
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(TravelInk.plan)
        .offset(x: axisWidth + actualWidth + columnWidth * CGFloat(block.column) + 2, y: CGFloat(block.startMinute) * minuteHeight)
        .accessibilityIdentifier("travelPlanBlock-\(block.id)")
    }
}

/// 시트를 내렸을 때 오른쪽에 뜨는 작은 시간 막대: 왼쪽 계획(남색), 오른쪽 실제(주홍). 누르면 계획표가 올라온다.
struct TravelMiniRail: View {
    let table: TravelPlanTableModel

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 8, height = size.height - 16
            func y(_ minute: Int) -> CGFloat { top + height * CGFloat(minute) / 1_440 }
            let half = (size.width - 14) / 2
            for block in table.blocks {
                let rect = CGRect(x: 6, y: y(block.startMinute), width: half, height: max(2, y(block.endMinute) - y(block.startMinute)))
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(TravelInk.plan.opacity(block.tripStatus == .tentative ? 0.4 : 0.85)))
                if block.status == .skipped { context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(TravelInk.actual), lineWidth: 1.5) }
            }
            for record in table.actuals {
                let rect = CGRect(x: 8 + half, y: y(record.startMinute), width: half, height: max(2, y(record.endMinute) - y(record.startMinute)))
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(TravelInk.actual.opacity(record.isMove ? 0.45 : 0.9)))
            }
            if let now = table.nowMinute {
                var line = Path()
                line.move(to: CGPoint(x: 2, y: y(now)))
                line.addLine(to: CGPoint(x: size.width - 2, y: y(now)))
                context.stroke(line, with: .color(TravelInk.actual), lineWidth: 1.5)
            }
        }
        .frame(width: 40)
        .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(TravelInk.border, lineWidth: 1) }
    }
}
