import MapKit
import SwiftUI
import TaptionPlanCore

/// 도감 시험 모드(PLB1109A03). 제목을 다섯 번 누르면 켜진다. 앱을 끄면 사라지고 기록에는 저장하지 않는다.
@MainActor
enum MapHomePlaceBookTestMode {
    static var isEnabled = false
    static var visits: [String: Date] = [:]

    static func toggleVisit(_ id: String, now: Date = .now) {
        if visits[id] == nil { visits[id] = now } else { visits[id] = nil }
    }
}

/// 나라별 입국 도장의 외곽 모양과 잉크 색(이미지 검색 사진을 보고 정함, 대표 지시 2026-11-09).
/// 국장·기관명·실제 문구는 쓰지 않는다. 자료가 없는 나라는 기본값을 쓴다.
struct MapHomePassportStampStyle: Equatable {
    enum Shape: Equatable { case rectangle, roundedRectangle, circle, oval, hexagon, octagon }

    let shape: Shape
    let colorHex: String

    static let standard = MapHomePassportStampStyle(shape: .circle, colorHex: "#2F5D8A")

    static func style(forCountry code: String) -> MapHomePassportStampStyle { table[code.lowercased()] ?? standard }

    private static let table: [String: MapHomePassportStampStyle] = [
        "ae": .init(shape: .oval, colorHex: "#2D4FA0"),
        "at": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "au": .init(shape: .octagon, colorHex: "#3A3A3A"),
        "bd": .init(shape: .rectangle, colorHex: "#333333"),
        "ca": .init(shape: .oval, colorHex: "#4A6F9A"),
        "ch": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "cn": .init(shape: .oval, colorHex: "#B23A35"),
        "cz": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "de": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "es": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "et": .init(shape: .oval, colorHex: "#3D6FA0"),
        "fi": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "fr": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "gr": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "gu": .init(shape: .oval, colorHex: "#3F5FA8"),
        "hu": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "id": .init(shape: .hexagon, colorHex: "#3D8F73"),
        "il": .init(shape: .rectangle, colorHex: "#3E7FA8"),
        "in": .init(shape: .oval, colorHex: "#4A4FA0"),
        "it": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "jp": .init(shape: .rectangle, colorHex: "#3F8FA8"),
        "kh": .init(shape: .roundedRectangle, colorHex: "#3457A0"),
        "kr": .init(shape: .circle, colorHex: "#2F7A8F"),
        "kz": .init(shape: .rectangle, colorHex: "#B6404A"),
        "la": .init(shape: .rectangle, colorHex: "#C0453F"),
        "mm": .init(shape: .rectangle, colorHex: "#32508F"),
        "mn": .init(shape: .rectangle, colorHex: "#2F8F6B"),
        "mp": .init(shape: .oval, colorHex: "#3F5FA8"),
        "mx": .init(shape: .rectangle, colorHex: "#3B9A5A"),
        "my": .init(shape: .rectangle, colorHex: "#3F3F9E"),
        "nl": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "no": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "np": .init(shape: .rectangle, colorHex: "#4560A8"),
        "nz": .init(shape: .rectangle, colorHex: "#333333"),
        "ph": .init(shape: .rectangle, colorHex: "#3E8E6E"),
        "pl": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "pt": .init(shape: .roundedRectangle, colorHex: "#2B2B2B"),
        "qa": .init(shape: .roundedRectangle, colorHex: "#2E4F9E"),
        "sg": .init(shape: .octagon, colorHex: "#333333"),
        "th": .init(shape: .rectangle, colorHex: "#B8404A"),
        "tr": .init(shape: .roundedRectangle, colorHex: "#333333"),
        "tw": .init(shape: .octagon, colorHex: "#3A5FA0"),
        "us": .init(shape: .oval, colorHex: "#3F5FA8"),
        "uz": .init(shape: .rectangle, colorHex: "#3B8E70"),
        "vn": .init(shape: .rectangle, colorHex: "#3B4A9C"),
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter
    }()

    /// 앱 언어와 관계없이 영어 일·월·년(09 NOV 2026).
    static func dateText(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        dateFormatter.timeZone = calendar.timeZone
        return dateFormatter.string(from: date).uppercased()
    }

    var outline: AnyShape {
        switch shape {
        case .rectangle: AnyShape(Rectangle())
        case .roundedRectangle: AnyShape(RoundedRectangle(cornerRadius: 6))
        case .circle: AnyShape(Circle())
        case .oval: AnyShape(Ellipse())
        case .hexagon: AnyShape(MapHomePassportPolygon(sides: 6))
        case .octagon: AnyShape(MapHomePassportPolygon(sides: 8))
        }
    }

    var isWide: Bool { shape != .circle && shape != .hexagon && shape != .octagon }
}

private struct MapHomePassportPolygon: Shape {
    let sides: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for index in 0..<sides {
            let angle = (Double(index) + 0.5) / Double(sides) * 2 * .pi
            let point = CGPoint(x: rect.midX + rect.width / 2 * cos(angle), y: rect.midY + rect.height / 2 * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// 공항·해외 도시의 여권 입국 도장(대표 결정 2026-11-09).
struct MapHomePassportStamp: View {
    let visitDate: Date?
    var countryCode = "kr"
    var size: CGFloat = 46

    var body: some View {
        let style = MapHomePassportStampStyle.style(forCountry: countryCode)
        let ink = Color(hex: style.colorHex)
        let width = style.isWide ? size * 1.3 : size
        ZStack {
            if let visitDate {
                style.outline.stroke(ink, lineWidth: max(1.5, size * 0.05))
                VStack(spacing: 0) {
                    Text(verbatim: "ENTRY").font(.system(size: size * 0.15, weight: .heavy, design: .monospaced))
                    Image(systemName: "airplane").font(.system(size: size * 0.22, weight: .bold))
                    Text(verbatim: MapHomePassportStampStyle.dateText(visitDate))
                        .font(.system(size: size * 0.135, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, size * 0.08)
                }
                .foregroundStyle(ink)
            } else {
                Circle().stroke(Color.tpLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                Image(systemName: "airplane").font(.system(size: size * 0.3)).foregroundStyle(Color.tpSecondary.opacity(0.6))
            }
        }
        .frame(width: visitDate == nil ? size : width, height: size)
        .rotationEffect(.degrees(visitDate == nil ? 0 : -12))
        .accessibilityHidden(true)
    }
}

/// 개발자에게 보내는 장소 등록 요청. 메일 화면에서 사용자가 직접 보낸다.
struct MapHomePlaceRequest: Codable, Equatable {
    var name: String
    var memo: String
    var latitude: Double
    var longitude: Double
    var requestedAt: Date
    var appBuild: String

    func writeJSON(to directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("BOKKI-place-request-\(Int(requestedAt.timeIntervalSince1970)).json")
        try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

struct MapHomePlaceRequestSheet: View {
    let language: MapHomeLanguage
    let currentCoordinate: CLLocationCoordinate2D?

    @State private var name = ""
    @State private var memo = ""
    @State private var query = ""
    @State private var center: CLLocationCoordinate2D?
    @State private var position: MapCameraPosition = .automatic
    @State private var attachment: MapHomeDeveloperAttachment?

    private var canSend: Bool { center != nil && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(language.text("장소 등록 요청", "Request a place"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                TextField(language.text("장소 이름", "Place name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(language.text("설명", "Description"), text: $memo, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField(language.text("장소 검색", "Search places"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    if let currentCoordinate {
                        Button { move(to: currentCoordinate) } label: {
                            Image(systemName: "location.fill").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel(language.text("현재 위치", "Current location"))
                    }
                }
                Map(position: $position)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
                    .overlay {
                        Image(systemName: "mappin")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(Color(hex: MapHomeInkWash.sealHex))
                            .offset(y: -15)
                            .allowsHitTesting(false)
                    }
                    .onMapCameraChange(frequency: .onEnd) { center = $0.camera.centerCoordinate }
                Text(language.text("지도를 움직여 핀을 맞춰 주세요.", "Move the map to place the pin."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                Button(action: send) {
                    Text(language.text("메일 보내기", "Send email"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .bold))
                        .foregroundStyle(Color.tpBackground)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(canSend ? Color.tpInk : Color.tpSecondary, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(20)
        }
        .background(Color.tpBackground)
        .onAppear { if let currentCoordinate { move(to: currentCoordinate) } }
        .sheet(item: $attachment) { MapHomeDeveloperMailSheet(attachment: $0) }
    }

    private func move(to coordinate: CLLocationCoordinate2D) {
        position = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
        center = coordinate
    }

    private func search() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        move(to: item.placemark.coordinate)
        if name.isEmpty { name = item.name ?? "" }
    }

    private func send() {
        guard let center else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let request = MapHomePlaceRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            memo: memo.trimmingCharacters(in: .whitespacesAndNewlines),
            latitude: center.latitude, longitude: center.longitude, requestedAt: .now, appBuild: build
        )
        guard let url = try? request.writeJSON() else { return }
        attachment = MapHomeDeveloperAttachment(url: url, subject: "BOKKI Plan place request: \(request.name)", mimeType: "application/json")
    }
}

extension AppModel {
    /// 여행 일정 한 곳을 더하고 그날 계획에도 넣는다. 정본은 설정의 일정 목록이다.
    @discardableResult
    func addTravelStop(title: String, latitude: Double, longitude: Double, day: Date) -> TravelPlanStop? {
        guard acceptsDataMutation() else { return nil }
        let start = Calendar.autoupdatingCurrent.startOfDay(for: day)
        let order = snapshot.settings.travelPlanStops.filter { $0.day == start }.count
        let planStart = start.addingTimeInterval(Double(9 + min(order * 2, 12)) * 3_600)
        let planID = addPlan(title: title, categoryID: "movement", startAt: planStart, duration: 3_600)
        let stop = TravelPlanStop(id: UUID(), title: title, latitude: latitude, longitude: longitude, day: start, order: order, planID: planID)
        snapshot.settings.travelPlanStops.append(stop)
        Task { await persist() }
        return stop
    }

    func removeTravelStop(_ id: UUID) async {
        guard acceptsDataMutation(), let stop = snapshot.settings.travelPlanStops.first(where: { $0.id == id }) else { return }
        snapshot.settings.travelPlanStops.removeAll { $0.id == id }
        snapshot.settings.travelPlanStops = TravelPlanSchedule.renumbered(snapshot.settings.travelPlanStops)
        if let planID = stop.planID { await deletePlan(planID) } else { await persist() }
    }

    func moveTravelStop(_ id: UUID, by offset: Int) {
        guard acceptsDataMutation() else { return }
        snapshot.settings.travelPlanStops = TravelPlanSchedule.moved(snapshot.settings.travelPlanStops, id: id, by: offset)
        Task { await persist() }
    }
}

/// 날짜별 순서 계산.
enum TravelPlanSchedule {
    static func days(_ stops: [TravelPlanStop]) -> [Date] { Array(Set(stops.map(\.day))).sorted() }

    static func stops(on day: Date, in stops: [TravelPlanStop]) -> [TravelPlanStop] {
        stops.filter { $0.day == day }.sorted { $0.order < $1.order }
    }

    static func renumbered(_ stops: [TravelPlanStop]) -> [TravelPlanStop] {
        days(stops).flatMap { day in
            self.stops(on: day, in: stops).enumerated().map { index, stop in
                var copy = stop
                copy.order = index
                return copy
            }
        }
    }

    static func moved(_ all: [TravelPlanStop], id: UUID, by offset: Int) -> [TravelPlanStop] {
        guard let stop = all.first(where: { $0.id == id }) else { return all }
        var day = stops(on: stop.day, in: all)
        guard let from = day.firstIndex(where: { $0.id == id }), day.indices.contains(from + offset) else { return all }
        day.swapAt(from, from + offset)
        let ordered = day.enumerated().map { index, item in
            var copy = item
            copy.order = index
            return copy
        }
        return all.filter { $0.day != stop.day } + ordered
    }
}

/// 여행 계획: 날짜별 핀과 순서대로 이은 경로.
struct MapHomeTripPlanSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    var onSelect: (MapHomePlaceBookPin) -> Void

    @State private var query = ""
    @State private var day = Calendar.autoupdatingCurrent.startOfDay(for: .now)

    private var stops: [TravelPlanStop] { model.settings.travelPlanStops }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(language.text("여행 계획", "Trip plan"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.headline), weight: .bold))
                DatePicker(language.text("날짜", "Date"), selection: $day, displayedComponents: .date)
                TextField(language.text("장소 검색", "Search places"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { Task { await addFromSearch() } }
                if stops.isEmpty {
                    Text(language.text("아직 담은 곳이 없습니다.", "No stops yet."))
                        .foregroundStyle(Color.tpSecondary)
                }
                ForEach(TravelPlanSchedule.days(stops), id: \.self) { date in
                    daySection(date, TravelPlanSchedule.stops(on: date, in: stops))
                }
            }
            .padding(20)
        }
        .background(Color.tpBackground)
    }

    private func addFromSearch() async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return }
        model.addTravelStop(
            title: item.name ?? query,
            latitude: item.placemark.coordinate.latitude,
            longitude: item.placemark.coordinate.longitude,
            day: day
        )
        query = ""
    }

    /// 한 곳뿐이면 자동 맞춤이 최대로 확대해 빈 지도가 된다.
    private func dayPosition(_ dayStops: [TravelPlanStop]) -> MapCameraPosition {
        guard dayStops.count == 1, let stop = dayStops.first else { return .automatic }
        return .region(MKCoordinateRegion(center: stop.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000))
    }

    private func daySection(_ date: Date, _ dayStops: [TravelPlanStop]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(date, format: .dateTime.month().day().weekday())
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.bodyStrong), weight: .bold))
            Map(initialPosition: dayPosition(dayStops)) {
                MapPolyline(coordinates: dayStops.map(\.coordinate))
                    .stroke(Color(hex: MapHomeInkWash.sealHex), lineWidth: 3)
                ForEach(Array(dayStops.enumerated()), id: \.element.id) { index, stop in
                    Marker(stop.title, monogram: Text(verbatim: "\(index + 1)"), coordinate: stop.coordinate)
                }
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: TaptionRadius.card, style: .continuous))
            .id(dayStops.map(\.id))
            ForEach(Array(dayStops.enumerated()), id: \.element.id) { index, stop in
                HStack {
                    Text(verbatim: "\(index + 1). \(stop.title)").lineLimit(1)
                    Spacer()
                    Button { model.moveTravelStop(stop.id, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 36, height: 44) }
                        .disabled(index == 0)
                    Button { model.moveTravelStop(stop.id, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 36, height: 44) }
                        .disabled(index == dayStops.count - 1)
                    Button { Task { await model.removeTravelStop(stop.id) } } label: { Image(systemName: "trash").frame(width: 36, height: 44) }
                        .accessibilityLabel(language.text("삭제", "Delete"))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(MapHomePlaceBookPin(title: stop.title, subtitle: "", latitude: stop.latitude, longitude: stop.longitude))
                }
            }
        }
    }
}

extension TravelPlanStop {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// 메인 지도의 여행 일정 번호 핀.
struct MapHomeTravelStopPin: View {
    let number: Int

    var body: some View {
        Text(verbatim: "\(number)")
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Color(hex: MapHomeInkWash.sealHex), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
    }
}

extension MapHomeView {
    /// 지금 고른 날의 여행 일정(PLB1109A03).
    var travelStopsOnSelectedDay: [TravelPlanStop] {
        TravelPlanSchedule.stops(
            on: Calendar.autoupdatingCurrent.startOfDay(for: model.selectedDate),
            in: model.settings.travelPlanStops
        )
    }

    func travelStopMarkerID(_ stop: TravelPlanStop) -> String { "travel-stop-\(stop.id.uuidString)" }

    private var travelRouteSignature: Int {
        var hasher = Hasher()
        for stop in travelStopsOnSelectedDay {
            hasher.combine(stop.latitude)
            hasher.combine(stop.longitude)
        }
        return hasher.finalize()
    }

    var vectorTravelRoutes: [MapHomeVectorRoute] {
        let stops = travelStopsOnSelectedDay
        guard stops.count >= 2 else { return [] }
        return [MapHomeVectorRoute(
            id: "travel-plan-route",
            coordinates: stops.map(\.coordinate),
            geometrySignature: travelRouteSignature,
            colorHex: MapHomeInkWash.sealHex,
            opacity: 0.85
        )]
    }

    var appleTravelRoutes: [MapHomeAppleRoute] {
        let stops = travelStopsOnSelectedDay
        guard stops.count >= 2 else { return [] }
        return [MapHomeAppleRoute(
            id: "travel-plan-route",
            coordinates: stops.map(\.coordinate),
            geometrySignature: travelRouteSignature,
            colorHex: MapHomeInkWash.sealHex,
            opacity: 0.85,
            phase: .forecast,
            transport: nil
        )]
    }
}
