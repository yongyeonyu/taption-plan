import SwiftUI
import TaptionPlanCore

/// 여행 일정 상태(TRP1110A09)의 문구·모양. 값과 저장 꼴은 `TaptionAssistantProtocol`에 있다(RMN1114A25).
extension TripItemStatus {
    func title(_ language: MapHomeLanguage) -> String {
        switch self {
        case .booked: language.text("예약됨", "Booked")
        case .planned: language.text("계획", "Planned")
        case .tentative: language.text("미정", "Tentative")
        }
    }

    /// VoiceOver용 이름. 계획이 아니면 상태를 뒤에 붙인다(REV1110A06).
    func spoken(_ title: String, _ language: MapHomeLanguage) -> String {
        self == .planned ? title : "\(title), \(self.title(language))"
    }

    var symbol: String? {
        switch self {
        case .booked: "checkmark.seal.fill"
        case .planned: nil
        case .tentative: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .booked: .green
        case .planned: Color.tpSecondary
        case .tentative: .orange
        }
    }
}

/// 미리보기 줄의 상태 배지(TRP1110A09).
struct TripItemStatusBadge: View {
    let status: TripItemStatus
    let language: MapHomeLanguage

    var body: some View {
        HStack(spacing: 3) {
            if let symbol = status.symbol { Image(systemName: symbol) }
            Text(status.title(language))
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .bold))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(status.tint.opacity(0.14), in: Capsule())
    }
}

/// 일정에서 한 번에 바꾸는 3단 선택(TRP1110A09).
struct TripItemStatusPicker: View {
    let language: MapHomeLanguage
    let status: TripItemStatus
    let onChange: (TripItemStatus) -> Void

    var body: some View {
        Picker(language.text("상태", "Status"), selection: Binding(get: { status }, set: { if $0 != status { onChange($0) } })) {
            ForEach(TripItemStatus.allCases) { Text($0.title(language)).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

extension AppModel {
    /// 여행 핀과 이어진 일정의 상태를 함께 바꾼다(TRP1110A09). 같은 값이면 저장하지 않는다.
    func setTravelStopStatus(_ status: TripItemStatus, stopID: UUID) {
        guard let stop = snapshot.settings.travelPlanStops.first(where: { $0.id == stopID }) else { return }
        if let tripID = stop.tripID, let itemID = stop.itemID {
            setTripItemStatus(status, tripID: tripID, itemID: itemID)
        } else if acceptsDataMutation(), let index = snapshot.settings.travelPlanStops.firstIndex(where: { $0.id == stopID }),
                  TripItemStatus(raw: stop.status) != status {
            snapshot.settings.travelPlanStops[index].status = TravelVisitMark.stored(TravelVisitMark(stored: stop.status), over: status.stored)
            Task { await persist() }
        }
    }

    /// 핀이 없는 일정(수면·좌표 없음)도 일정 번호로 상태를 바꾼다. 이어진 핀이 있으면 함께 바꾼다(REV1110A06).
    func setTripItemStatus(_ status: TripItemStatus, tripID: String, itemID: String) {
        // 함께 쓰는 여행의 상태는 공유 편집기로만 바꾼다(TSH1114A26).
        guard acceptsDataMutation(), !rejectsSharedTripEdit(tripID) else { return }
        var items = snapshot.settings.travelTripItems ?? []
        var stops = snapshot.settings.travelPlanStops
        var changed = false
        // 「갔음·건너뜀」 확정(TVZ1116C01)은 상태를 바꿔도 이어 붙인다. 그냥 덮으면 확정이 사라진다.
        func next(_ current: String?) -> String? { TravelVisitMark.stored(TravelVisitMark(stored: current), over: status.stored) }
        for index in items.indices where items[index].tripID == tripID && items[index].itemID == itemID && items[index].status != next(items[index].status) {
            items[index].status = next(items[index].status)
            changed = true
        }
        for index in stops.indices where stops[index].tripID == tripID && stops[index].itemID == itemID && stops[index].status != next(stops[index].status) {
            stops[index].status = next(stops[index].status)
            changed = true
        }
        guard changed else { return }
        if !items.isEmpty { snapshot.settings.travelTripItems = items }
        snapshot.settings.travelPlanStops = stops
        Task { await persist() }
    }
}

/// 지도 핀이 없는 여행 일정(수면·좌표 없는 곳)의 상태 선택 줄(REV1110A06).
struct TripUnpinnedItemStatusList: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    /// 핀이 없는 일정만 시작 시각 순으로.
    static func unpinned(_ items: [TravelTripItem], stops: [TravelPlanStop]) -> [TravelTripItem] {
        let pinned = Set(stops.compactMap { stop in stop.tripID.flatMap { trip in stop.itemID.map { "\(trip)|\($0)" } } })
        return items.filter { !pinned.contains("\($0.tripID)|\($0.itemID)") }.sorted { $0.start < $1.start }
    }

    /// 같은 이름(잠 등)을 구분하도록 그곳 현지 날짜·시각을 함께 보인다.
    private static func timeStyle(_ item: TravelTripItem, _ language: MapHomeLanguage) -> Date.FormatStyle {
        Date.FormatStyle(locale: language.locale, timeZone: TimeZone(secondsFromGMT: item.startOffsetSeconds) ?? .current)
            .month().day().hour().minute()
    }

    var body: some View {
        let items = Self.unpinned(model.settings.travelTripItems ?? [], stops: model.settings.travelPlanStops)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(language.text("지도 핀이 없는 일정", "Items without a map pin"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
                ForEach(items, id: \.self) { item in
                    let status = TripItemStatus(raw: item.status)
                    HStack {
                        Text(verbatim: item.title).lineLimit(1)
                        Spacer()
                        Text(item.start.formatted(Self.timeStyle(item, language)))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(status.spoken(item.title, language))
                    TripItemStatusPicker(language: language, status: status) {
                        model.setTripItemStatus($0, tripID: item.tripID, itemID: item.itemID)
                    }
                }
            }
        }
    }
}

extension MapHomeTimeRailSegment {
    /// 시간 막대 칠 농도. 예약은 진하게, 미정은 반투명(TRP1110A09).
    var railFillOpacity: Double {
        if categoryID == "unconfirmed" { return 0.50 }
        switch tripStatus {
        case .booked: return 1
        case .tentative: return 0.45
        default: return 0.94
        }
    }
}

/// 시간 막대 위 여행 상태 표시. 예약은 어둡게 덧칠하고 체크, 미정은 점선 테두리(TRP1110A09).
struct MapHomeTripStatusRailMark: View {
    let status: TripItemStatus?
    let height: CGFloat
    /// VoiceOver가 읽을 일정 이름. 색·점선만으로 알리지 않는다(REV1110A06).
    var title = ""

    var body: some View {
        if let status, status != .planned {
            mark.accessibilityElement().accessibilityLabel(status.spoken(title, MapHomeLanguage.current))
        }
    }

    @ViewBuilder private var mark: some View {
        switch status {
        case .booked:
            ZStack {
                Color.black.opacity(0.18)
                if height >= 12 {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .allowsHitTesting(false)
        case .tentative:
            Rectangle()
                .strokeBorder(Color.tpInk.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }
}

extension View {
    /// 지도 여행 핀: 미정은 반투명, 예약은 체크 배지(TRP1110A09). 배지는 핀 안쪽에 두어 34pt 지도 뷰에서 잘리지 않는다(REV1110A06).
    func tripStatusPinStyle(_ status: TripItemStatus) -> some View {
        overlay(alignment: .topTrailing) {
            if status == .booked {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.green)
                    .background(Circle().fill(.white))
            }
        }
        .opacity(status == .tentative ? 0.5 : 1)
    }
}
