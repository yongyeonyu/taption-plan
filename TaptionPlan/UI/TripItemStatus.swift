import SwiftUI
import TaptionPlanCore

/// 여행 일정 상태(TRP1110A09). 없거나 모르는 값은 계획이고, 계획은 저장하지 않아 예전 기록 바이트를 지킨다.
enum TripItemStatus: String, CaseIterable, Identifiable, Hashable {
    case booked, planned, tentative

    var id: String { rawValue }

    init(raw: String?) {
        self = raw.flatMap { Self(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .planned
    }

    /// 알아볼 수 있게 적힌 값만 읽는다. 없거나 모르는 값은 nil(REV1110A06).
    init?(explicit raw: String?) {
        guard let raw, let value = Self(rawValue: raw.trimmingCharacters(in: .whitespaces).lowercased()) else { return nil }
        self = value
    }

    /// 저장 값. 계획은 nil.
    var stored: String? { self == .planned ? nil : rawValue }

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
            snapshot.settings.travelPlanStops[index].status = status.stored
            Task { await persist() }
        }
    }

    /// 핀이 없는 일정(수면·좌표 없음)도 일정 번호로 상태를 바꾼다. 이어진 핀이 있으면 함께 바꾼다(REV1110A06).
    func setTripItemStatus(_ status: TripItemStatus, tripID: String, itemID: String) {
        guard acceptsDataMutation() else { return }
        var items = snapshot.settings.travelTripItems ?? []
        var stops = snapshot.settings.travelPlanStops
        var changed = false
        for index in items.indices where items[index].tripID == tripID && items[index].itemID == itemID && items[index].status != status.stored {
            items[index].status = status.stored
            changed = true
        }
        for index in stops.indices where stops[index].tripID == tripID && stops[index].itemID == itemID && stops[index].status != status.stored {
            stops[index].status = status.stored
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
