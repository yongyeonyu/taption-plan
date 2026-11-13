import CoreLocation
import TaptionPlanCore
import SwiftUI
import TaptionPlanStore

/// 여행 모드의 색(「여권 잉크」, 대표 결정 2026-11-11). 계획은 남색, 실제는 주홍.
enum TravelInk {
    static let space = Color(hex: "#1B2440")
    static let sea = Color(hex: "#D9E4EC")
    static let land = Color(hex: "#F6F1E4")
    static let border = Color(hex: "#C9C2AE")
    static let grid = Color(hex: "#C3CEDA")
    static let plan = Color(hex: "#2F3E6B")
    static let planTint = Color(hex: "#E3E7F2")
    static let actual = Color(hex: "#C8442E")
    /// 지도 위에 뜨는 판(머리말·돈 줄). 땅 색과 겹쳐 묻히지 않게 더 밝다.
    static let panel = Color.white.opacity(0.94)
    /// 깃발 기본 색. 여행 순서대로 돌려 쓴다(대표 지시: 사용자가 정하되 기본은 테마 색 순서).
    static let flagHexes = ["#C8442E", "#2F3E6B", "#C58B1B", "#2E7D6B", "#8A4F9E", "#D9722B"]

    static func flagHex(_ trip: TravelTrip, order: Int) -> String {
        trip.flagColorHex ?? flagHexes[max(0, order) % flagHexes.count]
    }

    /// 깃발 색 견본(메뉴용): 그 색으로 칠한 동그라미. 고른 색이면 가운데 흰 체크.
    static func swatch(_ hex: String, isChosen: Bool, side: CGFloat = 22) -> UIImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            UIColor(Color(hex: hex)).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
            guard isChosen else { return }
            UIColor.white.setStroke()
            let check = UIBezierPath()
            check.move(to: CGPoint(x: side * 0.30, y: side * 0.52))
            check.addLine(to: CGPoint(x: side * 0.45, y: side * 0.67))
            check.addLine(to: CGPoint(x: side * 0.72, y: side * 0.36))
            check.lineWidth = 2.2
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }

    static func flagName(_ hex: String, language: MapHomeLanguage) -> String {
        switch hex {
        case "#C8442E": language.text("주홍 깃발", "Vermilion flag")
        case "#2F3E6B": language.text("남색 깃발", "Navy flag")
        case "#C58B1B": language.text("겨자색 깃발", "Mustard flag")
        case "#2E7D6B": language.text("청록 깃발", "Teal flag")
        case "#8A4F9E": language.text("자주 깃발", "Purple flag")
        default: language.text("주황 깃발", "Orange flag")
        }
    }
}

/// 앱에 넣은 나라·시도 경계(`ne-regions.bin`). 처음 쓸 때 한 번 읽는다.
enum TravelModeRegions {
    static let bundled: [TravelGlobeRegion] = {
        guard let url = Bundle.main.url(forResource: "ne-regions", withExtension: "bin"), let data = try? Data(contentsOf: url) else { return [] }
        return (try? TravelGlobeRegions.decode(data)) ?? []
    }()

    static let countries = bundled.filter { $0.kind == .country }
    static let provinces = bundled.filter { $0.kind == .province }

    /// 경계 점을 지구 위 단위 벡터로 미리 바꿔 둔 것(곳 코드 → 고리들). 그릴 때마다 삼각함수를 다시 계산하지 않는다.
    static let vectors: [String: [[SIMD3<Double>]]] = Dictionary(
        bundled.map { region in (region.code, region.rings.map { ring in ring.map { unitVector(longitude: $0.x, latitude: $0.y) } }) },
        uniquingKeysWith: { first, _ in first }
    )

    /// 고리마다 가로·세로 가운데 큰 쪽의 크기(도). 화면에서 점 하나보다 작은 섬은 그리지 않는 데 쓴다.
    static let spans: [String: [Double]] = Dictionary(
        bundled.map { region in
            (region.code, region.rings.map { ring in
                let xs = ring.map(\.x), ys = ring.map(\.y)
                return max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
            })
        },
        uniquingKeysWith: { first, _ in first }
    )

    static func unitVector(longitude: Double, latitude: Double) -> SIMD3<Double> {
        let lambda = longitude * .pi / 180, phi = latitude * .pi / 180
        return SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }

    /// 그 나라의 통화(ISO 4217). 모르면 nil.
    static func currency(forCountry code: String) -> String? {
        Locale(identifier: "und_\(code)").currency?.identifier
    }
}

/// 여행 하나가 지구본에서 가리키는 곳.
struct TravelModeDestination {
    var country: TravelGlobeRegion?
    var province: TravelGlobeRegion?
    /// 깃발 자리(경도, 위도).
    var point: SIMD2<Double>?
    /// 그 여행의 지도 핀(날짜·순서대로).
    var stops: [TravelPlanStop]

    init(trip: TravelTrip, stops allStops: [TravelPlanStop]) {
        stops = allStops.filter { $0.tripID == trip.id }.sorted { ($0.day, $0.order) < ($1.day, $1.order) }
        var point: SIMD2<Double>?
        if let latitude = trip.latitude, let longitude = trip.longitude {
            point = SIMD2(longitude, latitude)
        } else if !stops.isEmpty {
            let sum = stops.reduce(SIMD2<Double>(0, 0)) { $0 + SIMD2($1.longitude, $1.latitude) }
            point = sum / Double(stops.count)
        }
        country = trip.countryCode.flatMap { code in TravelModeRegions.countries.first { $0.code == code } }
            ?? point.flatMap { TravelGlobeRegions.region(in: TravelModeRegions.countries, kind: .country, longitude: $0.x, latitude: $0.y) }
        if country?.code == "KR" {
            province = trip.regionName.flatMap { name in TravelModeRegions.provinces.first { $0.nameKo == name || $0.nameEn == name } }
                ?? point.flatMap { TravelGlobeRegions.region(in: TravelModeRegions.provinces, kind: .province, longitude: $0.x, latitude: $0.y) }
        }
        self.point = point ?? province.map(TravelModeRegions.landAnchor) ?? country.map(TravelModeRegions.flagPoint)
    }
}

extension TravelModeRegions {
    /// 나라만 정한 여행의 깃발 자리: 그 나라 대표 국제공항(TFP1113A01, 대표 신고 「일본인데 왜 바다에 꽂히냐? 공항에 꽂아야지」).
    static let countryAirports: [String: String] = [
        "KR": "ICN", "JP": "NRT", "CN": "PEK", "HK": "HKG", "MO": "MFM", "TW": "TPE",
        "TH": "BKK", "VN": "HAN", "PH": "MNL", "SG": "SIN", "MY": "KUL", "ID": "CGK",
        "GU": "GUM", "MP": "SPN", "MN": "UBN", "US": "LAX", "CA": "YVR",
        "GB": "LHR", "FR": "CDG", "DE": "FRA", "NL": "AMS", "IT": "FCO", "ES": "MAD",
        "CH": "ZRH", "AT": "VIE", "CZ": "PRG", "TR": "IST", "AE": "DXB", "QA": "DOH",
        "AU": "SYD", "NZ": "AKL",
    ]

    static func flagPoint(_ country: TravelGlobeRegion) -> SIMD2<Double> {
        if let code = countryAirports[country.code], let airport = TravelAirports.coordinate(code) {
            return SIMD2(airport.longitude, airport.latitude)
        }
        return landAnchor(country)
    }

    /// 가장 큰 땅을 감싼 네모의 가운데. 휜 섬처럼 그 자리가 바다면 그 땅 경계에서 가장 가까운 점으로 옮긴다.
    static func landAnchor(_ region: TravelGlobeRegion) -> SIMD2<Double> {
        let center = region.anchor
        guard !region.contains(longitude: center.x, latitude: center.y),
              let ring = region.rings.max(by: { $0.count < $1.count }) else { return center }
        func squared(_ point: SIMD2<Double>) -> Double { let d = point - center; return d.x * d.x + d.y * d.y }
        return ring.min { squared($0) < squared($1) } ?? center
    }
}

// MARK: - 계획표 판 높이(TVU1113A01, Trip 원본의 지도/일정 3단계)

/// 계획표 판의 높이: 내림(지도 넓게) · 반반(처음 높이) · 지도 접기(일정 넓게). 손잡이를 끌어 그 사이 높이로도 둘 수 있고 기기에 기억한다.
enum TravelPlanSheetHeight {
    /// 지도 접기에서도 머리말·돈 줄·일차 칩·하단 막대가 보이게 남기는 높이.
    static let chrome: CGFloat = 330

    /// 손잡이로 고를 수 있는 범위. 넓은 화면·가로는 오른쪽 판이라 높이를 바꾸지 않는다.
    static func range(_ size: CGSize) -> ClosedRange<CGFloat> {
        let base = TravelModeView.planTableHeight(size)
        guard !TravelModeView.isWide(size) else { return base...base }
        return min(220, base)...max(base, size.height - chrome)
    }

    /// 기억한 높이(없으면 0)를 지금 화면에 맞춘 값. 없으면 반반 높이.
    static func height(_ size: CGSize, stored: Double) -> CGFloat {
        let range = range(size)
        return stored > 0 ? min(max(CGFloat(stored), range.lowerBound), range.upperBound) : TravelModeView.planTableHeight(size)
    }

    /// 손잡이를 끈 만큼 바뀐 높이(위로 끌면 커진다). 화면 갱신이 드물게 4pt 단위로 맞춘다.
    static func dragged(from height: CGFloat, translation: CGFloat, size: CGSize) -> CGFloat {
        let range = range(size)
        return min(max(((height - translation) / 4).rounded() * 4, range.lowerBound), range.upperBound)
    }

    /// 지도가 접힌(일정이 넓은) 높이인지: 반반과 끝의 가운데보다 크면.
    static func isMapFolded(_ height: CGFloat, size: CGSize) -> Bool {
        let range = range(size)
        return range.upperBound > range.lowerBound && height > (TravelModeView.planTableHeight(size) + range.upperBound) / 2
    }

    /// 「지도 접기 / 지도 펼치기」 단추를 눌렀을 때의 높이.
    static func toggled(_ height: CGFloat, size: CGSize) -> CGFloat {
        isMapFolded(height, size: size) ? TravelModeView.planTableHeight(size) : range(size).upperBound
    }
}

/// 계획표 판 위의 막대: 가운데 손잡이(누르면 내리고 끌면 높이 조절), 오른쪽에 「지도 접기 / 지도 펼치기」.
struct TravelPlanHandleBar: View {
    let language: MapHomeLanguage
    let isMapFolded: Bool
    /// 높이를 바꿀 수 없는 배치(넓은 화면)면 단추를 숨긴다.
    let canResize: Bool
    let onLower: () -> Void
    let onToggleMap: () -> Void
    /// 끄는 동안의 이동량과, 손을 뗐는지.
    let onDrag: (CGFloat, Bool) -> Void

    var body: some View {
        Capsule().fill(TravelInk.border).frame(width: 44, height: 5).padding(.top, 7).padding(.bottom, 3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onLower)
            .highPriorityGesture(DragGesture(minimumDistance: 6)
                .onChanged { onDrag($0.translation.height, false) }
                .onEnded { onDrag($0.translation.height, true) }, isEnabled: canResize)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(language.text("계획표 내리기", "Close plan table"))
            .accessibilityIdentifier("travelPlanHandle")
            .overlay(alignment: .trailing) {
                if canResize {
                    Button(action: onToggleMap) {
                        Image(systemName: isMapFolded ? "rectangle.split.1x2" : "rectangle.expand.vertical")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(TravelInk.plan).frame(width: 44, height: 22)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                    .accessibilityLabel(isMapFolded ? language.text("지도 펼치기", "Expand map") : language.text("지도 접기", "Collapse map"))
                    .accessibilityIdentifier("travelPlanMapToggle")
                }
            }
    }
}

/// 일차 칩 줄(Trip 원본의 날짜 띠): 「1일차 11/20」. 누르면 그날 계획표.
struct TravelDayChips: View {
    let days: [(key: String, label: String)]
    let selected: String
    /// 오른쪽의 「코스 | 계획표」 전환(TVV1113A01).
    var showsCourse: Binding<Bool> = .constant(false)
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            chips
            Picker("", selection: showsCourse) {
                Image(systemName: "list.number").tag(true).accessibilityLabel(MapHomeLanguage.current.text("코스", "Course"))
                Image(systemName: "tablecells").tag(false).accessibilityLabel(MapHomeLanguage.current.text("계획표", "Plan table"))
            }
            .pickerStyle(.segmented)
            .frame(width: 88)
            .padding(.trailing, 10)
            .padding(.bottom, 4)
            .accessibilityIdentifier("travelPlanTabs")
        }
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(days, id: \.key) { day in
                    Button { onPick(day.key) } label: {
                        Text(day.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .foregroundStyle(day.key == selected ? TravelInk.land : TravelInk.plan)
                            .background(day.key == selected ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 4)
    }
}

/// 지도에서 길게 눌러 고른 자리(TVU1113A01).
enum TravelMapSpot {
    /// 주소를 못 찾았을 때의 이름: 좌표.
    static func fallbackName(latitude: Double, longitude: Double) -> String {
        String(format: "%.4f, %.4f", latitude, longitude)
    }

    /// 그 자리의 이름(장소 이름 → 동네 → 좌표). Apple 주소 찾기를 쓴다.
    static func place(latitude: Double, longitude: Double) async -> TravelItemPlace {
        let mark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)).first
        let name = [mark?.name, mark?.subLocality, mark?.locality].compactMap { $0 }.first { !$0.isEmpty }
        return TravelItemPlace(name: name ?? fallbackName(latitude: latitude, longitude: longitude), latitude: latitude, longitude: longitude)
    }

    /// 핀을 눌렀을 때 옮겨 갈 날과 재생 시각: 그 일정이 놓인 날(그곳 날짜)과 시작 분.
    static func focus(_ item: TravelTripItem) -> (dayKey: String, minute: Int) {
        let local = Int(item.start.timeIntervalSince1970) + item.startOffsetSeconds
        return (TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds), ((local % 86_400) + 86_400) % 86_400 / 60)
    }
}

// MARK: - 되돌리기·다시 하기(TVU1113A01, Trip 원본의 ↶ ↷)

/// 계획표에서 고친 걸음들(끌어 옮기기·길이 바꾸기·±5분, 일정 넣기·지우기)을 쌓아 여러 번 되돌리고 다시 한다. 앱을 닫으면 사라진다.
struct TravelPlanHistory: Equatable {
    struct Step: Equatable {
        var tripID: String
        var itemID: String
        /// 옮긴 분과 끝이 바뀐 분(둘 중 하나만 0이 아니다).
        var move: Int
        var resize: Int
        var summary: String
        /// 일정을 넣거나 지운 걸음이면 그 일정과 붙어 있던 장소, 그리고 이 걸음 뒤에 일정이 있는지(넣음 = true, 지움 = false).
        var item: TravelTripItem?
        var place: TravelItemPlace?
        var exists: Bool?
        /// 한 번에 함께 바뀐 걸음들(코스 순서 바꾸기). 되돌릴 때는 거꾸로 하나씩 되돌린다.
        var group: [Step] = []

        var inverse: Step {
            var step = self
            step.move = -move
            step.resize = -resize
            step.exists = exists.map { !$0 }
            step.group = group.reversed().map(\.inverse)
            return step
        }

        /// 코스 순서를 바꿔 여러 일정의 시각이 함께 옮겨진 걸음. 옮겨진 것이 없으면 nil.
        static func reorder(tripID: String, moves: [String: Int], title: String) -> Step? {
            let steps = moves.filter { $0.value != 0 }.sorted { $0.key < $1.key }
                .map { Step(tripID: tripID, itemID: $0.key, move: $0.value, resize: 0, summary: "") }
            return steps.isEmpty ? nil : Step(tripID: tripID, itemID: "", move: 0, resize: 0, summary: "↕ " + title, group: steps)
        }

        /// 일정을 넣은 걸음(`exists` true)이나 지운 걸음(false).
        static func existence(_ item: TravelTripItem, place: TravelItemPlace?, exists: Bool) -> Step {
            Step(tripID: item.tripID, itemID: item.itemID, move: 0, resize: 0, summary: (exists ? "＋ " : "－ ") + item.title, item: item, place: place, exists: exists)
        }
    }

    /// 그 일정에 붙어 있는 장소(지도 핀).
    static func place(of item: TravelTripItem, stops: [TravelPlanStop]) -> TravelItemPlace? {
        stops.first { $0.tripID == item.tripID && $0.itemID == item.itemID }.map { TravelItemPlace(name: $0.title, latitude: $0.latitude, longitude: $0.longitude) }
    }

    static let limit = 50
    private(set) var done: [Step] = []
    private(set) var undone: [Step] = []

    var tripID: String? { (done.last ?? undone.last)?.tripID }
    var canUndo: Bool { !done.isEmpty }
    var canRedo: Bool { !undone.isEmpty }
    /// 막대에 보일 글: 방금 한 것, 다 되돌렸으면 다시 할 것.
    var summary: String { (done.last ?? undone.last)?.summary ?? "" }

    /// 새로 고친 걸음. 다른 여행이면 앞의 쌓임을 버리고, 다시 하기 쌓임은 늘 비운다.
    mutating func record(_ step: Step) {
        if let tripID, tripID != step.tripID { done.removeAll() }
        undone.removeAll()
        done.append(step)
        if done.count > Self.limit { done.removeFirst(done.count - Self.limit) }
    }

    /// 되돌릴 걸음(저장소에 반영할 반대 방향). 없으면 nil.
    mutating func undo() -> Step? {
        guard let step = done.popLast() else { return nil }
        undone.append(step)
        return step.inverse
    }

    mutating func redo() -> Step? {
        guard let step = undone.popLast() else { return nil }
        done.append(step)
        return step
    }
}

extension AppModel {
    /// 일정을 지운다. 코스 곳이면 딸린 세부 계획도 함께 지우고, 한 번에 되돌릴 수 있는 걸음을 돌려준다(C4). 못 지웠으면 nil.
    func deleteTripItemWithDetails(tripID: String, itemID: String) async -> TravelPlanHistory.Step? {
        let items = settings.travelTripItems ?? []
        guard let item = items.first(where: { $0.tripID == tripID && $0.itemID == itemID }) else { return nil }
        var steps: [TravelPlanHistory.Step] = []
        for target in TravelTripItem.details(of: itemID, tripID: tripID, in: items) + [item] {
            let place = TravelPlanHistory.place(of: target, stops: settings.travelPlanStops)
            if await deleteTripItem(tripID: tripID, itemID: target.itemID) { steps.append(.existence(target, place: place, exists: false)) }
        }
        guard let last = steps.last, last.itemID == itemID else { return nil }
        return steps.count == 1 ? last : TravelPlanHistory.Step(tripID: tripID, itemID: "", move: 0, resize: 0, summary: last.summary, group: steps)
    }

    /// 되돌리기·다시 하기에서 나온 한 걸음을 저장소에 반영한다: 넣기·지우기면 일정을 되살리거나 지우고, 아니면 시각을 옮긴다.
    func applyTravelHistory(_ step: TravelPlanHistory.Step) async {
        if !step.group.isEmpty {
            for part in step.group { await applyTravelHistory(part) }
        } else if let exists = step.exists, let item = step.item {
            _ = exists ? await restoreTripItem(item, place: step.place) : await deleteTripItem(tripID: step.tripID, itemID: step.itemID)
        } else if step.move != 0 {
            _ = await moveTripItem(tripID: step.tripID, itemID: step.itemID, by: TimeInterval(step.move * 60))
        } else {
            _ = await resizeTripItem(tripID: step.tripID, itemID: step.itemID, endDelta: TimeInterval(step.resize * 60))
        }
    }
}

/// 계획표 아래의 되돌리기 줄: 방금 고친 것과 ↶ ↷.
struct TravelPlanHistoryBar: View {
    let history: TravelPlanHistory
    let language: MapHomeLanguage
    let onUndo: () -> Void
    let onRedo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.and.down")
            Text(history.summary).lineLimit(1)
            Spacer()
            button("arrow.uturn.backward", language.text("되돌리기", "Undo"), isOn: history.canUndo, id: "travelPlanUndo", action: onUndo)
            button("arrow.uturn.forward", language.text("다시 하기", "Redo"), isOn: history.canRedo, id: "travelPlanRedo", action: onRedo)
        }
        .font(.footnote)
        .foregroundStyle(TravelInk.plan)
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 32)
        .background(TravelInk.planTint, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }

    private func button(_ symbol: String, _ label: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 40, height: 32) }
            .buttonStyle(.plain)
            .opacity(isOn ? 1 : 0.3)
            .disabled(!isOn)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
    }
}

// MARK: - 코스 보기(TVV1113A01)

/// 코스 보기의 계산: 그날 일정을 시간 순서로 놓고, 재생 헤드 기준으로 지금 일정과 진행률을 고른다.
enum TravelCourse {
    /// 코스의 굵은 곳들을 시간 순서로(시작이 같으면 번호 순). 세부 계획은 빠지되, 딸린 곳이 그날에 없으면 굵은 곳으로 친다.
    static func ordered(_ blocks: [TravelPlanTableModel.Block]) -> [TravelPlanTableModel.Block] {
        let ids = Set(blocks.map(\.id))
        return blocks.filter { block in block.parentID.map { !ids.contains($0) || $0 == block.id } ?? true }
            .sorted { ($0.startMinute, $0.id) < ($1.startMinute, $1.id) }
    }

    /// 그 곳에 딸린 세부 계획들(시간 순서).
    static func details(of parent: TravelPlanTableModel.Block, in blocks: [TravelPlanTableModel.Block]) -> [TravelPlanTableModel.Block] {
        blocks.filter { $0.parentID == parent.id && $0.id != parent.id }.sorted { ($0.startMinute, $0.id) < ($1.startMinute, $1.id) }
    }

    /// 새 세부 계획의 시각: 그 곳 안에서 마지막 세부 끝(없으면 그 곳 시작)부터 30분, 그 곳 끝을 넘지 않게. 자리가 없으면 끝 15분.
    static func detailSlot(parent: TravelPlanTableModel.Block, details: [TravelPlanTableModel.Block]) -> (start: Int, duration: Int) {
        let length = max(5, parent.endMinute - parent.startMinute)
        let wanted = max(parent.startMinute, details.map(\.endMinute).max() ?? parent.startMinute)
        let start = min(wanted, parent.endMinute - min(15, length))
        return (start, max(5, min(30, parent.endMinute - start)))
    }

    /// 지금 일정: 그 시각이 든 일정(겹치면 늦게 시작한 것), 없으면 다음에 올 일정, 그것도 없으면 마지막 일정.
    static func currentIndex(_ blocks: [TravelPlanTableModel.Block], minute: Int) -> Int? {
        guard !blocks.isEmpty else { return nil }
        if let inside = blocks.lastIndex(where: { $0.startMinute <= minute && minute < $0.endMinute }) { return inside }
        return blocks.firstIndex { $0.startMinute > minute } ?? blocks.count - 1
    }

    /// 그 일정 안에서의 진행률(0~1). 시작 전이면 0, 끝난 뒤면 1.
    static func progress(_ block: TravelPlanTableModel.Block, minute: Int) -> Double {
        let length = max(1, block.endMinute - block.startMinute)
        return min(max(Double(minute - block.startMinute) / Double(length), 0), 1)
    }

    /// 이전·다음 단추가 옮겨 갈 시각. 끝이면 nil.
    static func neighborStart(_ blocks: [TravelPlanTableModel.Block], current: Int, step: Int) -> Int? {
        blocks.indices.contains(current + step) ? blocks[current + step].startMinute : nil
    }
}

/// 코스 보기: 위에 지금 일정 카드(그림·이름·진행 막대·이전/다음), 아래에 시간 순서 목록. 그림은 그 일정 시간에 찍은 사진, 없으면 일정 색에 종류 아이콘.
struct TravelCourseView: View {
    let table: TravelPlanTableModel
    /// 그날 일정의 실제 시각(사진을 찾을 때 쓴다).
    let items: [TravelTripItem]
    let language: MapHomeLanguage
    let playMinute: Int
    let photos: ApplePhotoLibraryService
    @Binding var selectedID: String?
    let onScrub: (Int) -> Void
    let onEdit: (TravelPlanTableModel.Block) -> Void
    /// 「곳 더하기」: 장소를 찾아 그날 코스 끝에 붙인다.
    var onAddStop: () -> Void = {}
    /// 그 곳에 세부 계획을 더한다(편집기가 그 곳 안의 시각으로 열린다).
    var onAddDetail: (TravelPlanTableModel.Block) -> Void = { _ in }
    /// 끌어서 순서를 바꿈: 함께 옮겨질 일정들의 걸음. 밀어서 지움.
    var onReorder: (TravelPlanHistory.Step) -> Void = { _ in }
    var onDelete: (TravelPlanTableModel.Block) -> Void = { _ in }
    /// 여행 전에 보일 위키백과 대표 사진(C6). 찍은 사진이 있으면 그것이 먼저다.
    var placePhotos: [String: TravelPlacePhoto] = [:]
    /// 순서를 바꿀 수 없을 때 잠깐 보이는 안내.
    @State private var notice = ""

    @State private var images: [String: UIImage] = [:]

    private var blocks: [TravelPlanTableModel.Block] { TravelCourse.ordered(table.blocks) }

    var body: some View {
        let blocks = self.blocks
        let current = TravelCourse.currentIndex(blocks, minute: playMinute)
        VStack(spacing: 0) {
            if let current {
                nowCard(blocks, current)
                Divider().overlay(TravelInk.border)
                if !notice.isEmpty {
                    Text(notice).font(.caption).foregroundStyle(TravelInk.actual).padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .task(id: notice) {
                            try? await Task.sleep(for: .seconds(4))
                            if !Task.isCancelled { notice = "" }
                        }
                }
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                            VStack(spacing: 0) {
                                row(block, order: index + 1, isCurrent: index == current)
                                // 지금 일정이거나 고른 곳은 펼쳐서 세부 계획과 「세부 더하기」를 보인다.
                                if index == current || selectedID == block.id { detailRows(block) }
                            }
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(index == current ? TravelInk.planTint : Color.clear)
                                .swipeActions(edge: .trailing) {
                                    Button(language.text("지우기", "Delete"), role: .destructive) { onDelete(block) }
                                }
                        }
                        // 길게 눌러 끌면 순서가 바뀌고, 시각은 그 구간 안에서 순서대로 다시 잡힌다.
                        .onMove { from, to in reorder(blocks, from: from, to: to) }
                        addStopButton.frame(maxWidth: .infinity).padding(.vertical, 8)
                            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 44)
                    .onChange(of: current) { _, index in withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(blocks[index].id, anchor: .center) } }
                }
            } else {
                VStack(spacing: 10) {
                    Text(language.text("갈 곳을 굵직하게 먼저 더해 보세요. 세부 계획은 나중에 적어도 됩니다.", "Add the main stops first. You can fill in details later."))
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(TravelInk.plan.opacity(0.7))
                    addStopButton
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(TravelInk.plan)
        .task(id: blocks.map(\.id)) { await loadPhotos(blocks) }
        .accessibilityIdentifier("travelCourse")
    }

    /// 펼친 곳 아래의 세부 계획 줄들과 「세부 더하기」.
    private func detailRows(_ parent: TravelPlanTableModel.Block) -> some View {
        VStack(spacing: 0) {
            ForEach(TravelCourse.details(of: parent, in: table.blocks)) { detail in
                Button { onEdit(detail) } label: {
                    HStack(spacing: 8) {
                        Text(clock(detail.startMinute)).font(.caption.monospacedDigit()).opacity(0.7).frame(width: 44, alignment: .leading)
                        Text(detail.title).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(TravelQuickEntrySheet.durationText(detail.endMinute - detail.startMinute, language: language)).font(.caption2).opacity(0.6)
                    }
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { onAddDetail(parent) } label: {
                Label(language.text("세부 더하기", "Add detail"), systemImage: "plus").font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("travelCourseAddDetail")
        }
        .padding(.leading, 84)
        .padding(.trailing, 12)
        .padding(.bottom, 4)
    }

    private func reorder(_ blocks: [TravelPlanTableModel.Block], from: IndexSet, to: Int) {
        guard let source = from.first, let tripID = items.first?.tripID else { return }
        guard let moves = TravelCoursePlanner.reorder(blocks, from: source, to: to) else {
            notice = language.text("예약된 일정이나 잠을 사이에 두고는 순서를 바꿀 수 없습니다.", "You can’t reorder across a booked plan or sleep.")
            return
        }
        if let step = TravelPlanHistory.Step.reorder(tripID: tripID, moves: moves, title: blocks[source].title) { onReorder(step) }
    }

    private var addStopButton: some View {
        Button(action: onAddStop) {
            Label(language.text("곳 더하기", "Add a stop"), systemImage: "plus").font(.footnote.weight(.medium))
                .padding(.horizontal, 14).frame(height: 36)
                .foregroundStyle(TravelInk.land).background(TravelInk.plan, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("travelCourseAddStop")
    }

    private func nowCard(_ blocks: [TravelPlanTableModel.Block], _ index: Int) -> some View {
        let block = blocks[index]
        return HStack(spacing: 10) {
            thumbnail(block, side: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(index + 1). " + block.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(clock(block.startMinute) + " – " + clock(block.endMinute) + " · " + TravelQuickEntrySheet.durationText(block.endMinute - block.startMinute, language: language))
                    .font(.caption.monospacedDigit()).opacity(0.8)
                ProgressView(value: TravelCourse.progress(block, minute: playMinute)).tint(TravelInk.plan)
                // 위키백과 사진을 보일 때는 작가·라이선스를 함께 적는다.
                if images[block.id] == nil, let credit = placePhotos[block.id]?.credit {
                    Text(credit).font(.system(size: 9)).opacity(0.6).lineLimit(1).accessibilityIdentifier("travelCoursePhotoCredit")
                }
                HStack {
                    Text(clock(playMinute)).font(.caption2.monospacedDigit()).opacity(0.7)
                    Spacer()
                    step("backward.end.fill", language.text("이전 일정", "Previous plan"), to: TravelCourse.neighborStart(blocks, current: index, step: -1))
                    step("forward.end.fill", language.text("다음 일정", "Next plan"), to: TravelCourse.neighborStart(blocks, current: index, step: 1))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("travelCourseNow")
    }

    private func step(_ symbol: String, _ label: String, to minute: Int?) -> some View {
        Button { if let minute { onScrub(minute) } } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 40, height: 28)
                .background(TravelInk.planTint, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(minute == nil ? 0.3 : 1)
        .disabled(minute == nil)
        .accessibilityLabel(label)
    }

    private func row(_ block: TravelPlanTableModel.Block, order: Int, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            Text("\(order)").font(.footnote.weight(.medium).monospacedDigit()).frame(width: 22)
            thumbnail(block, side: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).font(.footnote.weight(.medium)).lineLimit(1)
                Text(clock(block.startMinute) + " · " + TravelQuickEntrySheet.durationText(block.endMinute - block.startMinute, language: language))
                    .font(.caption2.monospacedDigit()).opacity(0.7)
            }
            Spacer(minLength: 0)
            if isCurrent { Image(systemName: "chart.bar.fill").font(.system(size: 13)).accessibilityHidden(true) }
            Button { onEdit(block) } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 14, weight: .medium)).frame(width: 36, height: 36) }
                .buttonStyle(.plain)
                .accessibilityLabel(language.text("속성", "Details"))
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .contentShape(Rectangle())
        .overlay(alignment: .bottomLeading) {
            // 세부 계획이 있으면 개수를 작게 알린다(펼친 줄에서는 아래에 다 보인다).
            let count = TravelCourse.details(of: block, in: table.blocks).count
            if count > 0, !(isCurrent || selectedID == block.id) {
                Text("+\(count)").font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(TravelInk.plan.opacity(0.7))
                    .padding(.leading, 78).padding(.bottom, 3)
            }
        }
        // 누르면 재생 헤드가 그 일정 시작으로 가고(지도의 고양이도 따라간다) 그 일정이 선택된다.
        .onTapGesture {
            if selectedID != block.id { selectedID = block.id }
            onScrub(block.startMinute)
        }
        .id(block.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// 그 일정 시간에 찍은 사진, 없으면 일정 색 바탕에 종류 아이콘.
    private func thumbnail(_ block: TravelPlanTableModel.Block, side: CGFloat) -> some View {
        ZStack {
            if let image = images[block.id] ?? placePhotos[block.id]?.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                TravelPlanTable.tint(block.colorHex)
                Image(systemName: TripImportItem.Kind(rawValue: block.kind)?.symbol ?? "mappin").font(.system(size: side * 0.4, weight: .semibold))
                    .foregroundStyle(TravelPlanTable.ink(block.colorHex))
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(TravelInk.border, lineWidth: 1) }
    }

    private func clock(_ minute: Int) -> String { TravelQuickEntrySheet.clock(minute) }

    /// 사진 접근이 이미 허용돼 있을 때만, 일정마다 그 시간에 찍은 첫 사진(화면 캡처 제외)을 작게 읽는다. 여기서 권한을 묻지 않는다.
    private func loadPhotos(_ blocks: [TravelPlanTableModel.Block]) async {
        guard photos.permissionState().isGranted else { return }
        let spans = Dictionary(items.map { ($0.itemID, TimeSpan(start: $0.start, end: $0.end)) }) { first, _ in first }
        let service = photos
        for block in blocks where images[block.id] == nil {
            guard let span = spans[block.id], !Task.isCancelled else { continue }
            guard let found = await service.firstPhotoID(in: span), let data = try? await service.thumbnailJPEG(localIdentifier: found, size: CGSize(width: 192, height: 192)),
                  let image = UIImage(data: data) else { continue }
            images[block.id] = image
        }
    }
}

/// 코스를 먼저 짜는 흐름의 계산(TVV1113A01): 어느 탭이 먼저인지, 새 곳의 시각, 찾은 장소의 종류.
enum TravelCoursePlanner {
    /// 계획표를 먼저 보기로 고른 여행이 아니면 코스가 먼저 열린다.
    static func showsCourse(_ tableTrips: String, tripID: String) -> Bool {
        !tableTrips.split(separator: ",").contains(Substring(tripID))
    }

    /// 탭을 고른 뒤의 기억 값. 오래된 여행 번호가 끝없이 쌓이지 않게 40개까지만 둔다.
    static func tableTrips(_ stored: String, tripID: String, showsCourse: Bool) -> String {
        var ids = stored.split(separator: ",").map(String.init).filter { $0 != tripID }
        if !showsCourse { ids.append(tripID) }
        return ids.suffix(40).joined(separator: ",")
    }

    /// 코스 끝에 붙일 새 곳의 시각: 그날 마지막 일정 끝(없으면 오늘은 지금, 아니면 09:00)에서 종류 기본 길이만큼. 하루를 넘으면 자정까지로 줄인다.
    /// 밤의 잠(수면)은 하루의 끝이라 건너뛰고 그 앞 일정 뒤에 잇는다.
    static func nextSlot(blocks: [TravelPlanTableModel.Block], kind: String, nowMinute: Int?) -> (start: Int, duration: Int) {
        let start = TravelQuickEntry.nextStart(lastEndMinute: blocks.filter { $0.kind != "sleep" }.map(\.endMinute).max(), nowMinute: nowMinute)
        return (start, max(TravelQuickEntry.step, min(TravelQuickEntry.defaultDuration(kind: kind), 1_440 - start)))
    }

    /// 코스 순서 바꾸기(C3): `from`번째를 `to` 자리(옮기기 전 번호)로. 바뀐 구간 안에서만 시각을 다시 잡는다 —
    /// 구간의 첫 시작과 일정 사이 틈은 자리에 그대로 두고, 길이는 일정을 따라간다. 구간 밖은 건드리지 않는다.
    /// 구간에 예약된 일정이나 잠이 끼어 있으면 nil(시각이 정해진 것이라 옮기지 않는다). 돌려주는 값은 일정별로 옮길 분.
    static func reorder(_ blocks: [TravelPlanTableModel.Block], from: Int, to: Int) -> [String: Int]? {
        guard blocks.indices.contains(from), (0...blocks.count).contains(to) else { return [:] }
        var order = blocks
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to)
        guard let low = order.indices.first(where: { order[$0].id != blocks[$0].id }),
              let high = order.indices.last(where: { order[$0].id != blocks[$0].id }) else { return [:] }
        guard !blocks[low...high].contains(where: { $0.tripStatus == .booked || $0.kind == "sleep" }) else { return nil }
        var moves: [String: Int] = [:], cursor = blocks[low].startMinute
        for index in low...high {
            let block = order[index]
            moves[block.id] = cursor - block.startMinute
            cursor += block.endMinute - block.startMinute
            if index < high { cursor += max(0, blocks[index + 1].startMinute - blocks[index].endMinute) }
        }
        return moves
    }

    /// 지도에 올릴 핀. 코스일 때(`blocks`가 있을 때)는 번호를 코스 목록의 순서로 맞추고 종류 아이콘·일정 색·지금 일정 표시를 붙인다(C5).
    static func mapPins(_ pins: [TravelGlobeRenderer.Pin], blocks: [TravelPlanTableModel.Block], minute: Int, photos: [String: TravelPlacePhoto] = [:]) -> [TravelStreetMap.Pin] {
        let ordered = TravelCourse.ordered(blocks)
        let current = TravelCourse.currentIndex(ordered, minute: minute).map { ordered[$0].id }
        return pins.map { pin in
            var mapPin = TravelStreetMap.Pin(longitude: pin.longitude, latitude: pin.latitude, label: pin.label, id: pin.id, title: pin.title)
            guard let index = ordered.firstIndex(where: { $0.id == pin.id }) else {
                // 코스에서 세부 계획의 핀은 번호 없이 둔다(번호는 굵은 곳만 센다).
                if !ordered.isEmpty { mapPin.label = "" }
                return mapPin
            }
            mapPin.label = "\(index + 1)"
            mapPin.symbol = TripImportItem.Kind(rawValue: ordered[index].kind)?.symbol ?? "mappin"
            mapPin.colorHex = ordered[index].colorHex
            mapPin.isCurrent = ordered[index].id == current
            mapPin.image = photos[pin.id]?.image
            // 이름표는 전처럼 골라 둔 핀에만 두되(겹침 정리), 지금 일정에는 늘 붙인다.
            if mapPin.isCurrent { mapPin.title = ordered[index].title }
            return mapPin
        }
    }

    /// Apple 지도가 알려 준 장소 분류(`MKPointOfInterestCategory`의 원래 값)로 일정 종류를 짐작한다. 모르면 관광.
    static func kind(forCategory raw: String?) -> String {
        guard let raw = raw?.lowercased() else { return "sight" }
        let table: [(String, [String])] = [
            ("cafe", ["cafe"]), ("meal", ["restaurant", "bakery", "brewery", "winery", "foodmarket"]),
            ("lodging", ["hotel", "campground"]), ("flight", ["airport"]),
            ("transfer", ["publictransport", "carrental", "parking", "gasstation", "evcharger"]), ("shopping", ["store"]),
        ]
        return table.first { $0.1.contains { raw.contains($0) } }?.0 ?? "sight"
    }
}

/// 여행 화면 하단 막대(메인 홈 하단 메뉴와 같은 높이): 다음 일정과 일정 수·예상 지출, 오른쪽 「+」 메뉴. 막대를 누르면 계획표가 오르내린다.
struct TravelTripFooter: View {
    struct Action: Identifiable {
        let id: String
        let symbol: String
        let run: () -> Void
        init(_ title: String, _ symbol: String, run: @escaping () -> Void) {
            id = title
            self.symbol = symbol
            self.run = run
        }
    }

    let items: [TravelTripItem]
    let tripID: String
    let language: MapHomeLanguage
    let actions: [Action]
    /// 「위키백과 사진 받기」 스위치. 연락처가 설정돼 있지 않으면 nil(안 보임).
    var wikiPhotos: Binding<Bool>?
    let onTap: () -> Void

    var body: some View {
        let next = items.first { $0.end > .now } ?? items.first
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(next.map { language.runtimeText("다음: \($0.title)", "Next: \($0.title)") } ?? language.text("아직 일정이 없습니다", "No plans yet"))
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                let planned = TravelPlanSpend.plannedTotal(items: items, tripID: tripID)
                let plannedText = LedgerMoney.text(planned, language: language)
                Text(language.runtimeText("일정 \(items.count)개", "\(items.count) plans") + (planned > 0 ? " · " + language.runtimeText("예상 \(plannedText)", "Planned \(plannedText)") : ""))
                    .font(.caption).opacity(0.8)
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(actions) { action in Button(action.id, systemImage: action.symbol, action: action.run) }
                if let wikiPhotos {
                    Toggle(language.text("위키백과 사진 받기", "Get Wikipedia photos"), systemImage: "photo", isOn: wikiPhotos)
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(TravelInk.land).frame(width: 44, height: 44)
                    .background(TravelInk.plan, in: Circle())
            }
            .accessibilityLabel(language.text("추가", "Add"))
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.leading, 20)
        .padding(.trailing, 6)
        .frame(height: MapHomeBottomBarMetrics.pillHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityIdentifier("travelPlanFooter")
    }
}

extension TravelPlacePhotoStore.Place {
    /// 그 여행에서 장소가 붙은 일정들. 이름은 지도 핀의 이름(장소 이름)이다.
    static func places(tripID: String, stops: [TravelPlanStop]) -> [TravelPlacePhotoStore.Place] {
        stops.compactMap { stop in
            guard stop.tripID == tripID, let itemID = stop.itemID, !stop.title.isEmpty else { return nil }
            return .init(itemID: itemID, name: stop.title, latitude: stop.latitude, longitude: stop.longitude)
        }
    }
}
