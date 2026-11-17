import SwiftUI
import TaptionPlanStore

// 지도 + 날짜 보드(TVY1116B01): 코스의 일정을 일차 칩에 끌어 놓아 다른 날로 옮기고, 그날 코스를 가까운 순서로 정리한다.
// 여행 화면에는 `travelDayBoard(…)` 한 줄로 붙고, 코스 줄·일차 칩·단추는 환경 값으로 이어진다.

/// 다른 날로 옮기기와 동선 정리의 계산.
enum TravelDayBoard {
    /// 끌어 놓을 때 싣는 글의 머리. 뒤에 일정 번호가 온다.
    static let dragPrefix = "bokki-trip-item:"

    static func dragText(_ itemID: String) -> String { dragPrefix + itemID }

    static func itemID(fromDrag text: String) -> String? {
        text.hasPrefix(dragPrefix) && text.count > dragPrefix.count ? String(text.dropFirst(dragPrefix.count)) : nil
    }

    /// 예약된 일정과 잠은 시각이 정해진 것이라 날만 바꾸고 시각은 그대로 둔다.
    static func keepsClock(_ item: TravelTripItem) -> Bool {
        TripItemStatus(raw: item.status) == .booked || item.kind == "sleep"
    }

    /// 일정을 `toDay`로 보낼 때 옮길 분. 그 날 코스 끝(`nextSlot` 규칙)에 붙이고 길이는 그대로 둔다. 같은 날이면 nil.
    /// `blocks`는 옮겨 갈 날의 일정들(옮기는 일정과 딸린 세부는 뺀 것).
    static func minutes(item: TravelTripItem, toDay: String, blocks: [TravelPlanTableModel.Block], nowMinute: Int?) -> Int? {
        let from = TravelMapSpot.focus(item)
        guard let days = TravelTripDay.days(from: from.dayKey, to: toDay), days != 0 else { return nil }
        let start = keepsClock(item) ? from.minute : TravelCoursePlanner.nextSlot(blocks: blocks, kind: item.kind, nowMinute: nowMinute).start
        return days * 1_440 + start - from.minute
    }

    /// 다른 날로 옮기는 걸음(되돌리기 한 걸음). 딸린 세부 계획은 저장할 때 같은 만큼 함께 옮겨진다.
    static func step(item: TravelTripItem, toDay: String, dayLabel: String, blocks: [TravelPlanTableModel.Block], nowMinute: Int?) -> TravelPlanHistory.Step? {
        guard let move = minutes(item: item, toDay: toDay, blocks: blocks, nowMinute: nowMinute) else { return nil }
        return .init(tripID: item.tripID, itemID: item.itemID, move: move, resize: 0, summary: "→ " + dayLabel + " " + item.title)
    }

    /// 일차 칩과 같은 이름: 「2일차 11/21」. 당일치기는 날이 하나라 옮길 곳이 없다.
    static func days(of trip: TravelTrip, language: MapHomeLanguage) -> [(key: String, label: String)] {
        TravelPlanDays.days(of: trip).enumerated().map { index, day in
            let label = language.runtimeText("\(index + 1)일차", "Day \(index + 1)")
            return (day.key, trip.isWish ? label : label + " " + TravelPlanDays.shortDate(day.key))
        }
    }

    /// 동선 정리에서 시각을 그대로 둘 곳: 예약·숙소·잠, 그리고 「A→B」로 앞뒤 곳을 잇는 이동·항공.
    static func isTimeFixed(_ block: TravelPlanTableModel.Block) -> Bool {
        block.tripStatus == .booked || ["lodging", "sleep", "transfer", "flight"].contains(block.kind)
    }

    /// 그날 코스의 굵은 곳들을 동선 정리의 입력으로. `pins`는 일정 번호별 지도 핀(위도, 경도), `fixedIDs`는 캘린더 고정 일정.
    static func sortStops(_ blocks: [TravelPlanTableModel.Block], pins: [String: (latitude: Double, longitude: Double)], fixedIDs: Set<String> = []) -> [TravelCourseSort.Stop] {
        TravelCourse.ordered(blocks).map { block in
            TravelCourseSort.Stop(
                id: block.id, startMinute: block.startMinute, endMinute: block.endMinute,
                latitude: pins[block.id]?.latitude, longitude: pins[block.id]?.longitude,
                isTimeFixed: isTimeFixed(block) || fixedIDs.contains(block.id)
            )
        }
    }
}

@MainActor
extension TravelDayBoard {
    /// 그 여행의 그날 계획표(실제 기록 없이 일정만).
    static func table(model: AppModel, tripID: String, dayKey: String) -> TravelPlanTableModel {
        let day = TravelTripDay.components(dayKey).flatMap(Calendar.autoupdatingCurrent.date(from:)) ?? .now
        return TravelPlanTableModel.make(items: model.settings.travelTripItems ?? [], tripID: tripID, day: day, actual: [], now: .now)
    }

    /// 일정을 그 날 코스 끝으로 옮긴다(공유 여행이면 방에 먼저 쓴다). 옮겼으면 되돌릴 걸음을 돌려준다.
    static func move(model: AppModel, tripID: String, itemID: String, toDay: String, dayLabel: String) async -> TravelPlanHistory.Step? {
        let items = model.settings.travelTripItems ?? []
        guard let item = items.first(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return nil }
        let family = Set([itemID] + TravelTripItem.details(of: itemID, tripID: tripID, in: items).map(\.itemID))
        let table = table(model: model, tripID: tripID, dayKey: toDay)
        guard let step = step(item: item, toDay: toDay, dayLabel: dayLabel, blocks: table.blocks.filter { !family.contains($0.id) }, nowMinute: table.nowMinute),
              await TripSharePlanEditor.moveItem(model: model, tripID: tripID, itemID: itemID, by: TimeInterval(step.move * 60)) else { return nil }
        return step
    }

    /// 그날 코스의 동선 정리 입력(지도 핀과 캘린더 고정 일정을 붙인 것).
    /// `blocks`를 넘기면(여행 화면이 이미 만든 그날 칸) 계획표를 다시 만들지 않는다.
    static func sortStops(model: AppModel, tripID: String, dayKey: String, blocks: [TravelPlanTableModel.Block]? = nil) -> [TravelCourseSort.Stop] {
        var pins: [String: (latitude: Double, longitude: Double)] = [:]
        for stop in model.settings.travelPlanStops where stop.tripID == tripID {
            if let itemID = stop.itemID { pins[itemID] = (stop.latitude, stop.longitude) }
        }
        let fixedPlans = Set(model.snapshot.plans.filter(\.isFixed).map(\.id))
        let fixedIDs = Set((model.settings.travelTripItems ?? []).filter { item in item.tripID == tripID && item.planID.map { fixedPlans.contains($0) } == true }.map(\.itemID))
        return sortStops(blocks ?? table(model: model, tripID: tripID, dayKey: dayKey).blocks, pins: pins, fixedIDs: fixedIDs)
    }
}

/// 코스 줄·일차 칩·단추가 여행 화면에 이어지는 끈.
struct TravelDayBoardLinks {
    var days: [(key: String, label: String)]
    var currentDay: String
    /// 정리할 수 있는 곳(핀이 있고 고정이 아닌 곳)이 한 구간에 둘 이상 있는가.
    var canSort: Bool
    /// 일정 번호, 옮겨 갈 날.
    var move: (String, String) -> Void
    var sort: () -> Void
}

extension EnvironmentValues {
    @Entry var travelDayBoard: TravelDayBoardLinks?
}

private struct TravelDayBoardHost: ViewModifier {
    enum Prompt {
        case sort(TravelCourseSort.Plan)
        case alreadySorted
    }

    let model: AppModel
    let tripID: String
    let trip: TravelTrip
    let dayKey: String
    let blocks: [TravelPlanTableModel.Block]?
    let language: MapHomeLanguage
    @Binding var history: TravelPlanHistory
    @State private var prompt: Prompt?

    func body(content: Content) -> some View {
        let days = TravelDayBoard.days(of: trip, language: language)
        let stops = TravelDayBoard.sortStops(model: model, tripID: tripID, dayKey: dayKey, blocks: blocks)
        content
            .environment(\.travelDayBoard, TravelDayBoardLinks(
                days: days, currentDay: dayKey, canSort: TravelCourseSort.movableGroups(stops).contains { $0.count > 1 },
                move: { itemID, day in move(itemID, to: day, label: days.first { $0.key == day }?.label ?? "") },
                sort: { prompt = TravelCourseSort.plan(stops).map(Prompt.sort) ?? .alreadySorted }
            ))
            .alert(title, isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), presenting: prompt) { prompt in
                if case .sort(let plan) = prompt {
                    Button(language.text("바꾸기", "Reorder")) { apply(plan) }
                    Button(language.text("취소", "Cancel"), role: .cancel) {}
                } else {
                    Button(language.text("확인", "OK")) {}
                }
            } message: { prompt in
                if case .sort(let plan) = prompt {
                    let before = TravelCourseSort.kilometers(plan.beforeMeters), after = TravelCourseSort.kilometers(plan.afterMeters)
                    Text(language.runtimeText(
                        "이동 거리 약 \(before) km → \(after) km (직선 거리 기준). 예약·숙소·이동과 첫 곳은 그대로 둡니다.",
                        "Travel distance about \(before) km → \(after) km (straight line). Booked plans, lodging, transfers, and the first stop stay put."
                    ))
                }
            }
    }

    private var title: String {
        if case .alreadySorted = prompt { return language.text("이미 가까운 순서입니다", "Already in the nearest order") }
        return language.text("동선 정리", "Tidy route")
    }

    private func move(_ itemID: String, to day: String, label: String) {
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .move(itemID: itemID, minutes: 0)) {
            Task {
                guard let step = await TravelDayBoard.move(model: model, tripID: tripID, itemID: itemID, toDay: day, dayLabel: label) else { return }
                withAnimation(.snappy(duration: 0.2)) { history.record(step) }
            }
        }
    }

    private func apply(_ plan: TravelCourseSort.Plan) {
        guard let step = TravelPlanHistory.Step.reorder(tripID: tripID, moves: plan.moves, title: language.text("동선 정리", "Tidy route")) else { return }
        TripSharePlanEditor.route(model: model, tripID: tripID, edit: .reorder(dayKey: dayKey)) {
            Task { if await TripSharePlanEditor.applyStep(model: model, step) { withAnimation(.snappy(duration: 0.2)) { history.record(step) } } }
        }
    }
}

/// 일차 칩에 붙인다: 코스의 일정을 끌어다 놓으면 그 날로 옮긴다. 놓을 수 있는 칩은 테두리로 알린다.
private struct TravelDayChipDrop: ViewModifier {
    let dayKey: String
    @Environment(\.travelDayBoard) private var board
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay { if isTargeted { Capsule().stroke(TravelInk.actual, lineWidth: 2) } }
            .dropDestination(for: String.self) { texts, _ in
                guard let board, dayKey != board.currentDay, let itemID = texts.lazy.compactMap(TravelDayBoard.itemID(fromDrag:)).first else { return false }
                board.move(itemID, dayKey)
                return true
            } isTargeted: { inside in
                let next = inside && board != nil && dayKey != board?.currentDay
                if next != isTargeted { isTargeted = next }
            }
    }
}

/// 코스 줄에 붙인다: 길게 눌러 끌면 일차 칩에 놓을 수 있다(목록 안에서 놓으면 전처럼 순서 바꾸기).
private struct TravelDayBoardDrag: ViewModifier {
    let itemID: String
    @Environment(\.travelDayBoard) private var board

    func body(content: Content) -> some View {
        if let board, board.days.count > 1 {
            content.draggable(TravelDayBoard.dragText(itemID))
        } else {
            content
        }
    }
}

extension View {
    /// 여행 화면의 계획 판에 붙인다: 일차 칩으로 옮기기와 동선 정리가 켜진다.
    func travelDayBoard(
        model: AppModel, tripID: String, trip: TravelTrip, dayKey: String, blocks: [TravelPlanTableModel.Block]? = nil, language: MapHomeLanguage,
        history: Binding<TravelPlanHistory>
    ) -> some View {
        modifier(TravelDayBoardHost(model: model, tripID: tripID, trip: trip, dayKey: dayKey, blocks: blocks, language: language, history: history))
    }

    func travelDayChipDrop(_ dayKey: String) -> some View { modifier(TravelDayChipDrop(dayKey: dayKey)) }

    func travelDayBoardDrag(_ itemID: String) -> some View { modifier(TravelDayBoardDrag(itemID: itemID)) }
}

/// 그날 코스의 「동선 정리」 단추. 정리할 곳이 없으면 보이지 않는다.
struct TravelCourseSortButton: View {
    let language: MapHomeLanguage
    @Environment(\.travelDayBoard) private var board

    var body: some View {
        if let board, board.canSort {
            Button(action: board.sort) {
                Label(language.text("동선 정리", "Tidy route"), systemImage: "point.topleft.down.curvedto.point.bottomright.up").font(.footnote.weight(.medium))
                    .padding(.horizontal, 14).frame(height: TaptionControl.chip)
                    .foregroundStyle(TravelInk.plan).background(TravelInk.planTint, in: Capsule())
                    .taptionTouchTarget(visualWidth: TaptionControl.primary, visualHeight: TaptionControl.chip)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("travelCourseSort")
        }
    }
}

/// 일정 편집기의 「다른 날로…」: 날짜 목록에서 골라 그 날 코스 끝으로 옮긴다(끌기가 어려운 사람용).
struct TravelDayMoveMenu: View {
    let model: AppModel
    let item: TravelTripItem
    let language: MapHomeLanguage
    /// 옮겼으면 되돌릴 걸음, 못 옮겼으면 nil.
    let onDone: (TravelPlanHistory.Step?) -> Void

    var body: some View {
        let current = TravelMapSpot.focus(item).dayKey
        let days = (model.settings.travelTrips ?? []).first { $0.id == item.tripID }.map { TravelDayBoard.days(of: $0, language: language) } ?? []
        if days.count > 1 {
            Menu(language.text("다른 날로…", "Move to another day…"), systemImage: "calendar") {
                ForEach(days.filter { $0.key != current }, id: \.key) { day in
                    Button(day.label) {
                        Task { onDone(await TravelDayBoard.move(model: model, tripID: item.tripID, itemID: item.itemID, toDay: day.key, dayLabel: day.label)) }
                    }
                }
            }
        }
    }
}
