import SwiftUI
import TaptionPlanStore

// MARK: - 계획표(TVD1112A01)

/// 계획표 하루치: 분류 열에 놓인 계획 칸, 그 옆에 나란히 보일 실제 기록, 지금 시각.
struct TravelPlanTableModel: Equatable {
    /// 열 구성(TVU1113A01). 기본은 이동 · 식사 · 관광 · 숙소이고, 여행마다 이름·순서·종류 묶음을 바꿀 수 있다.
    var columns = TravelPlanColumns.defaults

    struct Block: Identifiable, Equatable {
        let id: String
        var column: Int
        var startMinute: Int
        var endMinute: Int
        var title: String
        var tripStatus: TripItemStatus?
        var status: TravelPlanComparison.Status
        var hasNote = false
        /// 그 시간에 쓴 돈(원). 없으면 0.
        var spent = 0.0
        /// 일정 색(없으면 기본 남색)과 예상 지출(원, 없으면 0)(TVU1113A01).
        var colorHex: String?
        var planned = 0.0
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

    /// 기본 4열에서의 자리.
    static func column(forKind kind: String) -> Int { TravelPlanColumns.index(forKind: kind, in: TravelPlanColumns.defaults) }

    /// `day`는 기기 달력의 그날. 일정은 그곳 벽시계 시각에 놓는다(시간 막대와 같은 규칙).
    static func make(
        items: [TravelTripItem], tripID: String, day: Date, actual: [MapHomeTimeRailSegment], now: Date, spent: [String: Double] = [:],
        columns: [TravelTripColumn] = TravelPlanColumns.defaults, calendar: Calendar = .autoupdatingCurrent
    ) -> TravelPlanTableModel {
        var blocks: [Block] = []
        var spans: [TravelPlanComparison.Span] = []
        for item in items where item.tripID == tripID {
            guard let segment = TravelTripRail.segments([item], day: day, calendar: calendar).first else { continue }
            let column = TravelPlanColumns.index(forKind: item.kind, in: columns)
            blocks.append(Block(
                id: item.itemID, column: column, startMinute: segment.startMinute, endMinute: segment.endMinute, title: item.title,
                tripStatus: segment.tripStatus, status: .pending, hasNote: !(item.note ?? "").isEmpty, spent: spent[item.itemID] ?? 0,
                colorHex: item.colorHex, planned: item.plannedSpendKRW ?? 0
            ))
            spans.append(.init(id: item.itemID, start: segment.startMinute, end: segment.endMinute, isMove: item.kind == "transfer" || item.kind == "flight"))
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
            columns: columns,
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
    /// `YYYY-MM-DD` → `11/20`. 일차 칩에 붙인다.
    static func shortDate(_ key: String) -> String {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "\(parts[1])/\(parts[2])" : ""
    }

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

/// 계획표에서 고른 빈 셀(TVU1113A01): 빈 곳을 누르면 먼저 셀이 선택되고, 그 셀의 「+」를 눌러야 입력 시트가 열린다(Trip 원본의 셀 선택 → 추가).
struct TravelPlanCell: Equatable {
    var column: Int
    /// 15분 단위 시작.
    var minute: Int

    /// 선택한 길이(분). 처음에는 한 시간이고 위·아래 손잡이를 끌어 바꾼다(Trip 원본의 셀 길이 조절).
    var length = TravelPlanCell.defaultLength
    static let defaultLength = 60
    static let minimumLength = 15
    var endMinute: Int { min(minute + length, 1_440) }
    /// 손잡이로 길이를 바꿨을 때만 입력 시트에 넘길 길이. 안 바꿨으면 분류의 기본 길이를 쓴다.
    var chosenDuration: Int? { length == Self.defaultLength ? nil : endMinute - minute }

    /// 아래 손잡이: 끝을 옮긴다(15분 이상, 24시까지).
    func movingEnd(by delta: Int) -> TravelPlanCell {
        var cell = self
        cell.length = min(max(endMinute - minute + delta, Self.minimumLength), 1_440 - minute)
        return cell
    }

    /// 위 손잡이: 시작을 옮긴다(끝은 그대로, 0시부터 끝 15분 전까지).
    func movingStart(by delta: Int) -> TravelPlanCell {
        let start = min(max(minute + delta, 0), endMinute - Self.minimumLength)
        return TravelPlanCell(column: column, minute: start, length: endMinute - start)
    }

    enum Tap: Equatable {
        /// 빈 셀을 누름.
        case empty(TravelPlanCell)
        /// 선택된 셀의 「+」를 누름.
        case plus
        /// 시간축·있는 일정·칸 들어 올리기처럼 셀 밖.
        case elsewhere
    }

    /// 누른 뒤의 선택과, 입력 시트를 열 셀(「+」를 눌렀을 때만).
    static func after(_ tap: Tap, selected: TravelPlanCell?) -> (selected: TravelPlanCell?, opens: TravelPlanCell?) {
        switch tap {
        case .empty(let cell): (cell, nil)
        case .plus: (nil, selected)
        case .elsewhere: (nil, nil)
        }
    }
}

/// 계획표의 일정 선택(TVU1113A01, Trip 원본): 한 번 누르면 선택돼 선택 막대가 뜨고, 선택된 일정을 다시 누르면 편집기가 열린다.
enum TravelPlanSelection {
    static func after(tapped id: String, selected: String?) -> (selected: String?, opensEditor: Bool) {
        (id, selected == id)
    }

    /// 선택 막대의 −5분·+5분이 하루(0~24시)를 벗어나지 않는지.
    static func canNudge(_ minutes: Int, start: Int, end: Int) -> Bool {
        start + minutes >= 0 && end + minutes <= 1_440
    }
}

/// 계획표: 이동·식사·관광·숙소 열에 계획 칸을 놓고, 시간축 옆에 실제 기록을 나란히 둔다.
struct TravelPlanTable: View {
    let table: TravelPlanTableModel
    let language: MapHomeLanguage
    /// 선택된 일정을 다시 누르거나 선택 막대의 「속성」을 누름: 편집기를 연다.
    let onSelect: (TravelPlanTableModel.Block) -> Void
    /// 선택 막대의 지출·지우기.
    var onExpense: (TravelPlanTableModel.Block) -> Void = { _ in }
    var onDelete: (TravelPlanTableModel.Block) -> Void = { _ in }
    /// 선택한 빈 셀의 「+」를 누름: 그 셀(열·시작·길이).
    var onAdd: (TravelPlanCell) -> Void = { _ in }
    /// 눌러서 고른 빈 셀. 화면이 들고 있어 아래 「+」 메뉴도 이 셀을 쓴다(Trip 원본의 `addQuickItem`). 값이 바뀔 때만 갱신한다.
    var cell: Binding<TravelPlanCell?> = .constant(nil)
    private var selectedCell: TravelPlanCell? {
        get { cell.wrappedValue }
        nonmutating set { cell.wrappedValue = newValue }
    }
    /// 길게 눌러 끌어 옮김: 옮긴 분.
    var onMove: (TravelPlanTableModel.Block, Int) -> Void = { _, _ in }
    /// 들어 올린 칸의 아래 손잡이를 끌어 길이를 바꿈: 끝이 옮겨진 분.
    var onResize: (TravelPlanTableModel.Block, Int) -> Void = { _, _ in }

    /// 재생 헤드의 시각. 손잡이를 끌거나 시간축을 누르면 `onScrub`으로 새 시각을 알린다.
    var playMinute: Int?
    var onScrub: (Int) -> Void = { _ in }
    /// 재생 헤드의 시각 표를 누름(Trip 원본): 그 시각으로 지출을 넣는다.
    var onExpenseAt: (Int) -> Void = { _ in }
    @State private var position = ScrollPosition()
    /// 처음 자리를 잡았는지.
    @State private var didPlace = false

    /// 길게 눌러 들어 올린 칸. 들린 칸은 몸통을 끌면 옮겨지고 아래 손잡이를 끌면 길이가 바뀐다.
    @State private var liftedID: String?
    /// 끄는 동안의 변화(5분 단위로만 바뀌어 화면 갱신이 드물다).
    @State private var moveMinutes = 0
    @State private var resizeMinutes = 0
    /// 눌러서 고른 일정. 아래에 선택 막대가 뜬다. 화면이 들고 있어 지도 핀을 눌러도 같은 일정이 선택된다(Trip 원본).
    var selection: Binding<String?> = .constant(nil)
    private var selectedID: String? {
        get { selection.wrappedValue }
        nonmutating set { selection.wrappedValue = newValue }
    }
    /// 표를 밀어서 알린 마지막 시각. 바깥에서 재생 시각을 바꾸면(핀 누르기) 그 시각으로 표를 옮긴다.
    @State private var scrubbed: Int?
    @State private var isConfirmingDelete = false
    /// 셀 손잡이를 끌기 시작했을 때의 셀. 끄는 동안에는 표 스크롤을 멈춘다.
    @State private var cellDragBase: TravelPlanCell?

    /// 계획표 확대 배율(기기에 기억). 1분의 높이는 `0.9 × 배율`.
    @AppStorage("travelPlanZoom") private var zoom = 1.0
    static let zooms: [Double] = [0.6, 1, 1.5, 2.2]
    /// 두 손가락으로 벌리기 시작했을 때의 배율.
    @State private var pinchBase: Double?

    /// 두 손가락으로 벌리거나 오므린 배율(Trip 원본의 핀치): 단추와 같은 범위 안에서 0.05 단위로만 바뀌어 화면 갱신이 드물다.
    static func pinched(from base: Double, magnification: Double) -> Double {
        guard magnification.isFinite, magnification > 0 else { return base }
        let raw = (base * magnification / 0.05).rounded() * 0.05
        return min(max(raw, zooms[0]), zooms[zooms.count - 1])
    }
    private var minuteHeight: CGFloat { Self.minuteHeight * zoom }
    /// 앞 일정에서 오는 시간이 모자란 일정들.
    var tightIDs: Set<String> = []
    private let axisWidth = TravelPlanTable.leading - 12
    private let actualWidth: CGFloat = 12

    static let minuteHeight: CGFloat = 0.9
    /// 시간축과 실제 띠가 차지하는 왼쪽 너비.
    static let leading: CGFloat = 50
    static let dragStep = 5

    /// 끈 거리를 5분 단위 분으로. 시작이 0시 앞으로, 끝이 24시 뒤로 나가지 않게 막는다.
    static func moveDelta(translation: CGFloat, start: Int, end: Int, scale: CGFloat = 1) -> Int {
        let raw = Int((translation / (minuteHeight * scale) / CGFloat(dragStep)).rounded()) * dragStep
        return min(max(raw, -start), 1_440 - end)
    }

    /// 끝을 끈 거리를 5분 단위 분으로. 길이가 15분보다 짧아지거나 24시를 넘지 않게 막는다.
    static func resizeDelta(translation: CGFloat, start: Int, end: Int, scale: CGFloat = 1) -> Int {
        let raw = Int((translation / (minuteHeight * scale) / CGFloat(dragStep)).rounded()) * dragStep
        return min(max(raw, start + 15 - end), 1_440 - end)
    }

    /// 누른 자리의 열과 시각(15분 단위). 시간축 쪽을 누르면 nil.
    static func slot(x: CGFloat, y: CGFloat, width: CGFloat, scale: CGFloat = 1, columns: Int = 4) -> (column: Int, minute: Int)? {
        let columnWidth = (width - leading) / CGFloat(max(1, columns))
        guard x >= leading, columnWidth > 0, y >= 0 else { return nil }
        let column = min(max(1, columns) - 1, Int((x - leading) / columnWidth))
        return (column, TravelQuickEntry.snapped(Int(y / (minuteHeight * scale))))
    }

    /// 일정 색으로 칠한 칸 바탕과 테두리. 색이 없으면 기본 남색 계열.
    static func tint(_ hex: String?) -> Color { hex.map { Color(hex: $0).opacity(0.18) } ?? TravelInk.planTint }
    static func ink(_ hex: String?) -> Color { hex.map { Color(hex: $0) } ?? TravelInk.plan }

    /// 칸에 보일 돈: 쓴 돈이 있으면 그것(주홍), 없고 예상 지출이 있으면 그것(옅게). 둘 다 없으면 nil.
    static func money(spent: Double, planned: Double) -> (amount: Double, isPlanned: Bool)? {
        spent > 0 ? (spent, false) : planned > 0 ? (planned, true) : nil
    }

    /// 열 제목: 붙인 이름, 없으면 그 열 첫 종류의 이름(기본 4열은 이동·식사·관광·숙소), 종류도 없으면 「열 n」.
    static func title(_ column: TravelTripColumn, index: Int, language: MapHomeLanguage) -> String {
        if !column.name.isEmpty { return column.name }
        switch column.kinds.first {
        case "transfer": return language.text("이동", "Move")
        case "meal": return language.text("식사", "Meals")
        case "sight": return language.text("관광", "Sights")
        case "lodging": return language.text("숙소", "Stay")
        case let kind?: return TripImportItem.Kind(rawValue: kind)?.planName ?? kind
        case nil: return language.runtimeText("열 \(index + 1)", "Column \(index + 1)")
        }
    }

    private var titles: [String] { table.columns.enumerated().map { Self.title($0.element, index: $0.offset, language: language) } }
    /// 열 제목 줄을 길게 누름(Trip 원본): 열 편집을 연다.
    var onEditColumns: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 「실제」 글자 자리에 확대·축소 단추를 둔다(실제 띠는 시간축 옆 주홍 띠로 알아본다).
                Color.clear.frame(width: axisWidth + actualWidth, height: 1)
                ForEach(titles.indices, id: \.self) { index in
                    Text(titles[index]).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.4, perform: onEditColumns)
            .foregroundStyle(TravelInk.plan.opacity(0.8))
            .padding(.vertical, 6)
            .overlay(alignment: .leading) { zoomButtons }
            Divider().overlay(TravelInk.border)
            // Trip 원본처럼 재생 헤드는 가운데에 고정하고 표가 그 아래로 흐른다: 가운데에 온 시각이 재생 시각이다.
            GeometryReader { box in
                let half = box.size.height / 2
                ScrollView {
                    // 위아래로 반 화면씩 비워 0시와 24시도 가운데까지 온다.
                    VStack(spacing: 0) {
                        Color.clear.frame(height: half)
                        dayBody
                        Color.clear.frame(height: half)
                    }
                }
                .scrollPosition($position)
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? zoom
                        if pinchBase == nil { pinchBase = base }
                        let next = Self.pinched(from: base, magnification: value.magnification)
                        if abs(next - zoom) > 0.001 { zoom = next }
                    }
                    .onEnded { _ in pinchBase = nil })
                // 칸을 들어 올린 동안에는 스크롤을 멈춰, 손잡이를 끌 때 표가 대신 밀리지 않게 한다.
                .scrollDisabled(liftedID != nil || cellDragBase != nil)
                .onScrollGeometryChange(for: Int.self) { geometry in
                    Self.scrubMinute(start: 0, translation: geometry.contentOffset.y, scale: zoom)
                } action: { _, minute in
                    if didPlace, minute != playMinute {
                        scrubbed = minute
                        onScrub(minute)
                    }
                }
                .onChange(of: playMinute) { _, minute in
                    guard didPlace, let minute, minute != scrubbed else { return }
                    scrubbed = minute
                    withAnimation(.snappy(duration: 0.25)) { position.scrollTo(y: CGFloat(minute) * minuteHeight) }
                }
                .overlay(alignment: .leading) { if let playMinute { playhead(playMinute, width: box.size.width) } }
                .overlay(alignment: .bottom) {
                    if let block = table.blocks.first(where: { $0.id == selectedID }) { selectionBar(block) }
                }
                // 배율을 바꿔도 보던 시각이 가운데에 남게 한다.
                .onChange(of: zoom) { _, _ in position.scrollTo(y: CGFloat(playMinute ?? table.focusMinute) * minuteHeight) }
                .task {
                    // 처음 그린 뒤에 옮겨야 자리가 잡힌다. 그 전의 스크롤 보고(0시)는 재생 시각으로 치지 않는다.
                    await Task.yield()
                    position.scrollTo(y: CGFloat(playMinute ?? table.focusMinute) * minuteHeight)
                    didPlace = true
                }
            }
        }
    }

    /// 계획표 확대·축소: 한 단계씩. 끝에서는 흐려진다.
    private var zoomButtons: some View {
        let index = Self.zooms.firstIndex { $0 >= zoom - 0.01 } ?? 1
        return HStack(spacing: 2) {
            zoomButton("minus.magnifyingglass", language.text("계획표 축소", "Zoom out"), isOn: index > 0) { zoom = Self.zooms[max(0, index - 1)] }
            zoomButton("plus.magnifyingglass", language.text("계획표 확대", "Zoom in"), isOn: index < Self.zooms.count - 1) { zoom = Self.zooms[min(Self.zooms.count - 1, index + 1)] }
        }
        .padding(.leading, 2)
    }

    private func zoomButton(_ symbol: String, _ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 22, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(TravelInk.plan.opacity(isOn ? 0.9 : 0.3))
        .disabled(!isOn)
        .accessibilityLabel(label)
    }

    /// 하루 전체(0~24시)를 그린 본문. 스크롤 없이도 그릴 수 있게 따로 둔다.
    var dayBody: some View {
        GeometryReader { proxy in
            let columnWidth = (proxy.size.width - axisWidth - actualWidth) / CGFloat(max(1, table.columns.count))
            ZStack(alignment: .topLeading) {
                grid(width: proxy.size.width)
                ForEach(table.actuals) { record in actualBar(record, columnWidth: columnWidth) }
                if let selectedCell { cellAddButton(selectedCell, columnWidth: columnWidth) }
                ForEach(table.blocks) { block in planBlock(block, columnWidth: columnWidth) }
                if let now = table.nowMinute {
                    Rectangle().fill(TravelInk.actual).frame(width: proxy.size.width, height: 1.5).offset(y: CGFloat(now) * minuteHeight)
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
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { value in
            if selectedID != nil { selectedID = nil }
            // 들어 올린 칸이 있으면 먼저 내려놓는다.
            if liftedID != nil {
                liftedID = nil
            } else if value.location.x < Self.leading {
                // 시간축을 누르면 그 시각이 가운데(재생 헤드)로 온다.
                withAnimation(.snappy(duration: 0.25)) { position.scrollTo(y: value.location.y) }
                tap(.elsewhere)
            } else if let slot = Self.slot(x: value.location.x, y: value.location.y, width: width, scale: zoom, columns: table.columns.count) {
                tap(.empty(TravelPlanCell(column: slot.column, minute: slot.minute)))
            }
        })
        .accessibilityIdentifier("travelPlanGrid")
    }

    /// 누른 것에 따라 선택을 옮기거나 풀고, 「+」면 입력 시트를 연다.
    private func tap(_ tap: TravelPlanCell.Tap) {
        let next = TravelPlanCell.after(tap, selected: selectedCell)
        if next.selected != selectedCell {
            selectedCell = next.selected
            if next.selected != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
        if let cell = next.opens { onAdd(cell) }
    }

    /// 선택된 셀: 주홍 테두리 칸 안의 「+」와 시작 시각. 누르면 입력 시트가 그 시각으로 열린다.
    private func cellAddButton(_ cell: TravelPlanCell, columnWidth: CGFloat) -> some View {
        Button { tap(.plus) } label: {
            VStack(spacing: 1) {
                Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                Text(cell.chosenDuration == nil ? Self.clock(cell.minute) : Self.clock(cell.minute) + "–" + Self.clock(cell.endMinute))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: columnWidth - 4, height: max(30, CGFloat(cell.endMinute - cell.minute) * minuteHeight))
            .background(TravelInk.actual.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).stroke(TravelInk.actual, lineWidth: 1.5) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { cellHandle(isEnd: false) }
        .overlay(alignment: .bottom) { cellHandle(isEnd: true) }
        .foregroundStyle(TravelInk.actual)
        .offset(x: axisWidth + actualWidth + columnWidth * CGFloat(cell.column) + 2, y: CGFloat(cell.minute) * minuteHeight)
        .accessibilityLabel(language.text("일정 넣기", "Add plan"))
        .accessibilityValue(Self.clock(cell.minute))
        .accessibilityIdentifier("travelPlanCellAdd")
    }

    /// 선택 막대(Trip 원본): 고른 일정의 시각과 −5분·+5분·지출·속성·지우기.
    private func selectionBar(_ block: TravelPlanTableModel.Block) -> some View {
        HStack(spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
                Text(block.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(Self.clock(block.startMinute) + "–" + Self.clock(block.endMinute)).font(.system(size: 10).monospacedDigit()).opacity(0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            nudgeButton(block, minutes: -5, label: language.text("−5분", "−5 min"))
            nudgeButton(block, minutes: 5, label: language.text("+5분", "+5 min"))
            barIcon("wonsign.circle", language.text("지출 넣기", "Add expense"), id: "Expense") { onExpense(block) }
            barIcon("slider.horizontal.3", language.text("속성", "Details"), id: "Details") { onSelect(block) }
            barIcon("trash", language.text("지우기", "Delete"), id: "Delete") { isConfirmingDelete = true }
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 44)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(TravelInk.border, lineWidth: 1) }
        .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
        .confirmationDialog(language.text("이 일정을 지울까요?", "Delete this plan?"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button(language.text("지우기", "Delete"), role: .destructive) {
                selectedID = nil
                onDelete(block)
            }
        }
        .accessibilityIdentifier("travelPlanSelectionBar")
    }

    private func nudgeButton(_ block: TravelPlanTableModel.Block, minutes: Int, label: String) -> some View {
        let isOn = TravelPlanSelection.canNudge(minutes, start: block.startMinute, end: block.endMinute)
        return Button(label) { onMove(block, minutes) }
            .font(.caption.weight(.semibold).monospacedDigit())
            .buttonStyle(.plain)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(TravelInk.planTint, in: Capsule())
            .opacity(isOn ? 1 : 0.35)
            .disabled(!isOn)
    }

    private func barIcon(_ symbol: String, _ label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 40) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityIdentifier("travelPlanSelection" + id)
    }

    /// 선택된 셀의 위·아래 손잡이: 끌면 시작이나 끝이 5분 단위로 바뀐다.
    private func cellHandle(isEnd: Bool) -> some View {
        Capsule().fill(TravelInk.actual).frame(width: 22, height: 4)
            .frame(maxWidth: .infinity).frame(height: 12, alignment: isEnd ? .bottom : .top)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard let base = cellDragBase ?? selectedCell else { return }
                    if cellDragBase == nil { cellDragBase = base }
                    let delta = Int((value.translation.height / minuteHeight / CGFloat(Self.dragStep)).rounded()) * Self.dragStep
                    let next = isEnd ? base.movingEnd(by: delta) : base.movingStart(by: delta)
                    if next != selectedCell {
                        selectedCell = next
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                .onEnded { _ in cellDragBase = nil })
            .accessibilityLabel(language.text("길이 바꾸기", "Change length"))
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
                .offset(x: axisWidth + actualWidth + columnWidth * CGFloat(TravelPlanColumns.index(forKind: "sight", in: table.columns)) + 2, y: CGFloat(record.startMinute) * minuteHeight)
                .accessibilityLabel(language.text("계획에 없던 방문", "Unplanned stop"))
        }
    }

    private func planBlock(_ block: TravelPlanTableModel.Block, columnWidth: CGFloat) -> some View {
        let isLifted = liftedID == block.id
        let start = block.startMinute + (isLifted ? moveMinutes : 0)
        let end = block.endMinute + (isLifted ? moveMinutes + resizeMinutes : 0)
        let height = max(18, CGFloat(end - start) * minuteHeight)
        let missed = block.status == .skipped
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                if block.status == .done { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                if block.status == .late { Image(systemName: "clock.badge.exclamationmark").font(.system(size: 9)).foregroundStyle(TravelInk.actual) }
                if tightIDs.contains(block.id) { Image(systemName: "figure.run").font(.system(size: 9, weight: .bold)).foregroundStyle(TravelInk.actual) }
                if block.hasNote { Image(systemName: "note.text").font(.system(size: 8)).opacity(0.7) }
                if block.spent > 0, height <= 46 || isLifted { Image(systemName: "wonsign.circle.fill").font(.system(size: 9)).foregroundStyle(TravelInk.actual) }
                Text(block.title).font(.caption2.weight(.semibold)).lineLimit(height > 30 ? 2 : 1)
            }
            if height > 34 || isLifted {
                Text(isLifted ? Self.clock(start) + "–" + Self.clock(end) : Self.clock(start)).font(.system(size: 10).monospacedDigit()).opacity(0.75)
            }
            if let money = Self.money(spent: block.spent, planned: block.planned), height > 46, !isLifted {
                Text((money.isPlanned ? "≈ " : "") + LedgerMoney.text(money.amount, language: language)).font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(money.isPlanned ? TravelInk.plan.opacity(0.7) : TravelInk.actual).lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .padding(3)
        .frame(width: columnWidth - 4, height: height, alignment: .topLeading)
        .background(isLifted ? Color.white : Self.tint(block.colorHex).opacity(block.tripStatus == .tentative ? 0.5 : 1), in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5).stroke(
                missed ? TravelInk.actual : Self.ink(block.colorHex),
                style: StrokeStyle(lineWidth: isLifted || selectedID == block.id ? 2.5 : block.tripStatus == .booked || missed ? 1.5 : 1, dash: block.tripStatus == .tentative ? [3, 3] : [])
            )
        }
        .overlay(alignment: .bottom) { if isLifted { resizeHandle(block) } }
        .shadow(color: .black.opacity(isLifted ? 0.25 : 0), radius: 6, y: 3)
        .contentShape(Rectangle())
        // 들린 칸은 눌러도 그대로 둔다(길게 누른 손을 뗄 때 바로 내려놓이지 않게). 내려놓기는 빈 곳을 누른다.
        .onTapGesture {
            guard !isLifted else { return }
            tap(.elsewhere)
            let next = TravelPlanSelection.after(tapped: block.id, selected: selectedID)
            if next.selected != selectedID { selectedID = next.selected }
            if next.opensEditor { onSelect(block) }
        }
        .gesture(moveGesture(block))
        .foregroundStyle(TravelInk.plan)
        .offset(x: axisWidth + actualWidth + columnWidth * CGFloat(block.column) + 2, y: CGFloat(start) * minuteHeight)
        .zIndex(isLifted ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("travelPlanBlock-\(block.id)")
    }

    /// 손잡이를 끈 거리만큼 옮긴 시각(1분 단위, 하루 안).
    static func scrubMinute(start: Int, translation: CGFloat, scale: CGFloat = 1) -> Int {
        min(max(start + Int((translation / (minuteHeight * scale)).rounded()), 0), 1_439)
    }

    /// 재생 헤드: 가운데에 고정된 남색 선과 왼쪽의 시각 표. 선은 누르는 것을 아래 표에 넘기고, 시각 표를 누르면 그 시각으로 지출을 넣는다.
    private func playhead(_ minute: Int, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(TravelInk.plan).frame(width: width, height: 2).allowsHitTesting(false)
            Button { onExpenseAt(minute) } label: {
                Text(Self.clock(minute)).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(TravelInk.land)
                    .frame(width: Self.leading - 4, height: 24)
                    .background(TravelInk.plan, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("재생 헤드", "Playhead"))
            .accessibilityValue(Self.clock(minute))
            .accessibilityHint(language.text("지출 넣기", "Add expense"))
            .accessibilityIdentifier("travelPlayhead")
        }
        .frame(width: width, height: 24, alignment: .leading)
    }

    private static func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60 % 24, minute % 60) }

    /// 길게 누르면 들리고, 그대로 끌면 옮겨진다. 손을 떼면 그 자리에 놓는다(들린 채로 남아 길이 손잡이를 쓸 수 있다).
    private func moveGesture(_ block: TravelPlanTableModel.Block) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .onEnded { _ in
                liftedID = block.id
                if selectedID != block.id { selectedID = block.id }
                tap(.elsewhere)
                moveMinutes = 0
                resizeMinutes = 0
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                let next = Self.moveDelta(translation: drag.translation.height, start: block.startMinute, end: block.endMinute, scale: zoom)
                if next != moveMinutes {
                    moveMinutes = next
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                let moved = moveMinutes
                moveMinutes = 0
                if moved != 0 { onMove(block, moved) }
            }
    }

    /// 들린 칸 아래의 손잡이: 끌면 끝 시각이 바뀐다.
    private func resizeHandle(_ block: TravelPlanTableModel.Block) -> some View {
        Capsule().fill(TravelInk.plan).frame(width: 26, height: 5)
            // 칸 밖은 눌리지 않으므로 손잡이 자리를 칸 안쪽 아래 20pt로 둔다.
            .frame(maxWidth: .infinity).frame(height: 20, alignment: .bottom)
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let next = Self.resizeDelta(translation: value.translation.height, start: block.startMinute, end: block.endMinute, scale: zoom)
                    if next != resizeMinutes {
                        resizeMinutes = next
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
                .onEnded { _ in
                    let changed = resizeMinutes
                    resizeMinutes = 0
                    if changed != 0 { onResize(block, changed) }
                })
            .accessibilityLabel(language.text("길이 바꾸기", "Change length"))
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
