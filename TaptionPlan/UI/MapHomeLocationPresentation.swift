import Foundation
import SwiftUI

enum MapHomeLocationDestination: String, CaseIterable, Identifiable {
    case home
    case company
    case school
    case exercise
    case hobby
    case restaurant
    case user

    var id: String { rawValue }

    var placeKind: FrequentPlaceKind? {
        switch self {
        case .home: .home
        case .company: .company
        case .school: .school
        case .exercise: .exercise
        case .hobby: .hobby
        case .restaurant: .restaurant
        case .user: nil
        }
    }

    init?(placeKind: FrequentPlaceKind) {
        switch placeKind {
        case .home: self = .home
        case .company: self = .company
        case .school: self = .school
        case .exercise: self = .exercise
        case .hobby: self = .hobby
        case .restaurant: self = .restaurant
        case .academy: return nil
        case .custom: self = .user
        }
    }

    var koreanName: String {
        switch self {
        case .home: "집"
        case .company: "회사"
        case .school: "학교"
        case .exercise: "운동"
        case .hobby: "취미"
        case .restaurant: "식당"
        case .user: "사용자"
        }
    }

    var englishName: String {
        switch self {
        case .home: "Home"
        case .company: "Work"
        case .school: "School"
        case .exercise: "Exercise"
        case .hobby: "Hobby"
        case .restaurant: "Restaurant"
        case .user: "User"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .company: "building.2.fill"
        case .school: "graduationcap.fill"
        case .exercise: "figure.run"
        case .hobby: "paintpalette.fill"
        case .restaurant: "storefront.fill"
        case .user: "mappin.and.ellipse"
        }
    }

    var tint: Color {
        switch self {
        case .home: Color.tpPastelButter
        case .company: Color.tpPastelSky
        case .school: Color.tpPastelMint
        case .exercise: Color.tpPastelRose
        case .hobby: Color.tpPastelLavender
        case .restaurant: Color.tpPastelButter
        case .user: Color.tpPastelRose
        }
    }
}

struct MapHomeLocationThumbnail: View {
    let destination: MapHomeLocationDestination
    var size: CGFloat = 42

    var body: some View {
        Group {
            if destination == .home {
                Image("MapHomeHouseMarker")
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(destination.tint.opacity(0.14))
                    Image(systemName: destination.systemImage)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(destination.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum MapHomeStickmanAction: String, CaseIterable, Hashable, Sendable {
    case activity
    case computer
    case reading
    case hobby
    case sleeping
    case movement
    case eating
    case exercise
    case unconfirmed
    case walking
    case running
    case car
    case subway
    case privateVehicle
    case bus
    case ship
    case airplane
    case cycling

    var title: String {
        switch self {
        case .activity: "활동"
        case .computer: "업무"
        case .reading: "수업"
        case .hobby: "취미"
        case .sleeping: "수면"
        case .movement: "이동"
        case .eating: "식사"
        case .exercise: "운동"
        case .unconfirmed: "미확인"
        case .walking: "걷기"
        case .running: "달리기"
        case .car: "자동차"
        case .subway: "지하철 탑승"
        case .privateVehicle: "자가용"
        case .bus: "버스 탑승"
        case .ship: "배"
        case .airplane: "비행기"
        case .cycling: "자전거"
        }
    }
}

enum MapHomeStickmanActionResolver {
    static func action(
        at date: Date,
        actuals: [ActualRecord],
        travel: [TravelSegment],
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        readings: [SensorReading] = []
    ) -> MapHomeStickmanAction {
        if let segment = travel
            .filter({ $0.span.contains(date) })
            .max(by: { $0.span.start < $1.span.start }) {
            return action(for: segment.mode)
        }

        let nearbyMovement = readings
            .filter {
                $0.motion.isMovement
                    && abs($0.timestamp.timeIntervalSince(date)) <= 3 * 60
            }
            .min {
                abs($0.timestamp.timeIntervalSince(date))
                    < abs($1.timestamp.timeIntervalSince(date))
            }
        if let nearbyMovement {
            return action(for: nearbyMovement.motion)
        }

        let activeActuals = actuals.compactMap { actual -> (ActualRecord, MapHomeStickmanAction)? in
            guard active(actual, at: date),
                  let action = action(for: actual) else { return nil }
            return (actual, action)
        }
        if let candidate = activeActuals.max(by: higherPriority) {
            return candidate.1
        }

        let activePlaces = places
            .filter { $0.span.contains(date) }
            .sorted { $0.span.start > $1.span.start }
        for place in activePlaces {
            if let action = action(for: place, frequentPlaces: frequentPlaces) {
                return action
            }
        }
        return .activity
    }

    static func action(for mode: TravelMode) -> MapHomeStickmanAction {
        switch mode {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .car, .taxi: .car
        case .subway, .train: .subway
        case .bus: .bus
        case .airplane: .airplane
        case .ship: .ship
        }
    }

    static func action(
        for categoryID: String,
        label: String
    ) -> MapHomeStickmanAction {
        let category = categoryID.lowercased()
        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        let value = "\(category) \(label)".lowercased()
        let detailMappings: [(String, MapHomeStickmanAction)] = [
            ("movement.walking", .walking),
            ("movement.running", .running),
            ("movement.car", .car),
            ("movement.subway", .subway),
            ("movement.privatevehicle", .privateVehicle),
            ("movement.bus", .bus),
            ("movement.ship", .ship),
            ("movement.airplane", .airplane),
            ("movement.cycling", .cycling)
        ]
        if let mapping = detailMappings.first(where: { value.contains($0.0) }) {
            return mapping.1
        }
        if categoryRoot == "unconfirmed" || categoryRoot == "unknown"
            || value.contains("unconfirmed") || value.contains("unknown")
            || value.contains("미확인") {
            return .unconfirmed
        }
        if value.contains("running") || value.contains("달리기") {
            return .running
        }
        if value.contains("subway") || value.contains("metro") || value.contains("지하철") {
            return .subway
        }
        if value.contains("privatevehicle") || value.contains("자가용") {
            return .privateVehicle
        }
        if value.contains("bus") || value.contains("버스") {
            return .bus
        }
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("ship") || value.contains("선박") || normalizedLabel == "배" {
            return .ship
        }
        if value.contains("airplane") || value.contains("비행기") || value.contains("항공") {
            return .airplane
        }
        if value.contains("cycling") || value.contains("bike") || value.contains("자전거") {
            return .cycling
        }
        if value.contains("car") || value.contains("driving")
            || value.contains("자동차") || value.contains("차량") {
            return .car
        }
        if value.contains("sleep") || value.contains("수면") || value.contains("잠") {
            return .sleeping
        }
        if value.contains("eating") || value.contains("food")
            || value.contains("식사") || value.contains("밥") {
            return .eating
        }
        if value.contains("work") || value.contains("업무")
            || value.contains("회사") || value.contains("컴퓨터") {
            return .computer
        }
        if value.contains("study") || value.contains("학교")
            || value.contains("수업") || value.contains("독서") {
            return .reading
        }
        if value.contains("exercise") || value.contains("운동") { return .exercise }
        if value.contains("hobby") || value.contains("취미") { return .hobby }
        switch categoryRoot {
        case "activity": return .activity
        case "work": return .computer
        case "study": return .reading
        case "hobby": return .hobby
        case "sleep": return .sleeping
        case "movement":
            if value.contains("걷") || value.contains("walk") || value.contains("walking") { return .walking }
            return .movement
        case "eating", "food": return .eating
        case "exercise": return .exercise
        case "unconfirmed", "unknown": return .unconfirmed
        default: break
        }
        if value.contains("movement") || value.contains("이동") { return .movement }
        return .activity
    }

    static func action(for motion: MotionKind) -> MapHomeStickmanAction {
        switch motion {
        case .walking: .walking
        case .running: .running
        case .cycling: .cycling
        case .automotive: .car
        case .stationary: .activity
        case .unknown: .unconfirmed
        }
    }

    private static func active(_ actual: ActualRecord, at date: Date) -> Bool {
        actual.startedAt <= date
            && (actual.endedAt == nil || date <= actual.endedAt!)
    }

    private static func action(for actual: ActualRecord) -> MapHomeStickmanAction? {
        let category = actual.categoryID.lowercased()
        let text = ([actual.title, actual.behavior] + actual.evidence)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        let categoryRoot = category.split(separator: ".", maxSplits: 1).first.map(String.init) ?? category
        if category.contains("movement.privatevehicle") || contains(text, ["privatevehicle", "자가용"]) {
            return .privateVehicle
        }
        if category.contains("movement.bus") || contains(text, ["버스", "bus"]) {
            return .bus
        }
        if category.contains("movement.ship") || contains(text, ["선박", "ship"]) || containsToken(text, "배") {
            return .ship
        }
        if category.contains("movement.airplane") || contains(text, ["항공", "비행기", "airplane"]) {
            return .airplane
        }
        if ["activity", "work", "study", "hobby", "sleep", "movement", "eating", "exercise", "unconfirmed", "unknown"].contains(categoryRoot) {
            return action(for: category, label: text)
        }

        if categoryRoot == "sleep" || contains(text, ["수면", "잠", "sleep"]) {
            return .sleeping
        }
        if categoryRoot == "eating"
            || categoryRoot == "food"
            || contains(text, ["식사", "밥", "meal", "eating"]) {
            return .eating
        }
        if categoryRoot == "work"
            || contains(text, ["회사", "근무", "업무", "컴퓨터", "work"]) {
            return .computer
        }
        if categoryRoot == "study"
            || contains(text, ["학교", "수업", "학습", "독서", "study"]) {
            return .reading
        }
        if contains(text, ["지하철", "subway", "metro"]) {
            return .subway
        }
        if contains(text, ["자동차", "차량", "운전", "car", "driving"]) {
            return .car
        }
        if contains(text, ["자전거", "cycling", "bike"]) {
            return .cycling
        }
        if contains(text, ["달리기", "running"]) {
            return .running
        }
        if contains(text, ["걷", "walking", "walk"]) {
            return .walking
        }
        switch category {
        case "activity": return .activity
        case "hobby": return .hobby
        case "movement": return .movement
        case "exercise": return .exercise
        case "unconfirmed", "unknown": return .unconfirmed
        default: return nil
        }
    }

    private static func action(
        for place: PlaceStay,
        frequentPlaces: [FrequentPlace]
    ) -> MapHomeStickmanAction? {
        if let frequent = frequentPlaces.first(where: {
            $0.stablePlaceKey == place.placeKey
        }) {
            switch frequent.kind {
            case .company: return .computer
            case .school, .academy: return .reading
            case .restaurant: return .eating
            case .home, .custom: return .activity
            case .hobby: return .hobby
            case .exercise: return .exercise
            }
        }

        let text = [place.displayName, place.buildingName]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        if contains(text, ["회사", "근무", "work"]) { return .computer }
        if contains(text, ["학교", "학원", "school"]) { return .reading }
        if contains(text, ["식당", "restaurant", "meal"]) { return .eating }
        if contains(text, ["취미", "hobby"]) { return .hobby }
        return .activity
    }

    private static func higherPriority(
        _ lhs: (ActualRecord, MapHomeStickmanAction),
        _ rhs: (ActualRecord, MapHomeStickmanAction)
    ) -> Bool {
        let leftRank = priority(of: lhs.0)
        let rightRank = priority(of: rhs.0)
        if leftRank != rightRank { return leftRank > rightRank }
        if lhs.0.startedAt != rhs.0.startedAt {
            return lhs.0.startedAt > rhs.0.startedAt
        }
        return lhs.0.id.uuidString > rhs.0.id.uuidString
    }

    private static func priority(of actual: ActualRecord) -> Int {
        let category = actual.categoryID.lowercased()
        let text = ([actual.title, actual.behavior] + actual.evidence)
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        let semanticRank: Int
        if category == "sleep" || contains(text, ["수면", "잠", "sleep"]) {
            semanticRank = 80
        } else if category == "eating" || category == "food"
                    || contains(text, ["식사", "밥", "meal", "eating"]) {
            semanticRank = 70
        } else if category == "work"
                    || contains(text, ["회사", "근무", "업무", "work"]) {
            semanticRank = 60
        } else if category == "study"
                    || contains(text, ["학교", "수업", "학습", "독서", "study"]) {
            semanticRank = 50
        } else {
            semanticRank = 10
        }
        return semanticRank + (actual.manuallyCorrected ? 1_000 : 0)
    }

    private static func contains(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func containsToken(_ text: String, _ token: String) -> Bool {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .contains(token)
    }
}

enum MapHomeStickmanAnimationEngine {
    static let frameDuration: TimeInterval = 0.08
    static let phaseCount = 12

    static func phase(at date: Date, reducesMotion: Bool = false) -> Int {
        guard !reducesMotion else { return 0 }
        let elapsed = date.timeIntervalSinceReferenceDate / frameDuration
        guard elapsed.isFinite, abs(elapsed) < 9e15 else { return 0 }
        let step = Int64(floor(elapsed))
        let count = Int64(phaseCount)
        return Int(((step % count) + count) % count)
    }

    static func oscillation(for phase: Int) -> Double {
        sin(2 * .pi * Double(phase) / Double(phaseCount))
    }

    static func secondaryOscillation(for phase: Int) -> Double {
        sin(4 * .pi * Double(phase) / Double(phaseCount))
    }

    static func pulse(for phase: Int) -> Double {
        (oscillation(for: phase) + 1) / 2
    }
}

enum MapHomeStickmanStyle {
    static let deepPinkHex = "#D94772"
    static let personStrokeWidth: CGFloat = 1
}

struct MapHomeStickmanMarker: View {
    static let size = CGSize(width: 49, height: 42)

    let action: MapHomeStickmanAction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: MapHomeStickmanAnimationEngine.frameDuration,
                paused: reduceMotion
            )
        ) { context in
            Canvas { canvas, size in
                MapHomeStickmanRenderer.draw(
                    context: &canvas,
                    size: size,
                    action: action,
                    phase: MapHomeStickmanAnimationEngine.phase(
                        at: context.date,
                        reducesMotion: reduceMotion
                    )
                )
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(.white.opacity(0.96), in: Circle())
        .overlay { Circle().stroke(Color.tpPastelRose.opacity(0.42), lineWidth: 1) }
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
        .accessibilityHidden(true)
    }
}

struct MapHomeStickmanGlyph: View {
    let action: MapHomeStickmanAction
    var size: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: MapHomeStickmanAnimationEngine.frameDuration,
                paused: reduceMotion
            )
        ) { context in
            Canvas { canvas, canvasSize in
                MapHomeStickmanRenderer.draw(
                    context: &canvas,
                    size: canvasSize,
                    action: action,
                    phase: MapHomeStickmanAnimationEngine.phase(
                        at: context.date,
                        reducesMotion: reduceMotion
                    )
                )
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct MapHomeStickmanCanvas {
    let size: CGSize
    let scale: CGFloat
    let origin: CGPoint

    init(size: CGSize) {
        self.size = size
        scale = min(size.width / 64, size.height / 56)
        origin = CGPoint(
            x: (size.width - 64 * scale) / 2,
            y: (size.height - 56 * scale) / 2
        )
    }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }

    func rect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + x * scale,
            y: origin.y + y * scale,
            width: width * scale,
            height: height * scale
        )
    }
}

private enum MapHomeStickmanRenderer {
    private static let deepPink = Color(hex: MapHomeStickmanStyle.deepPinkHex)
    private static let accent = deepPink
    private static let line = deepPink
    private static let faceLine = Color.black.opacity(0.9)
    private static let propLine = Color.black.opacity(0.9)
    private static let propFill = Color.white.opacity(0.92)
    private static let fill = propFill

    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        action: MapHomeStickmanAction,
        phase: Int
    ) {
        let canvas = MapHomeStickmanCanvas(size: size)
        drawGroundShadow(&context, canvas: canvas, action: action, phase: phase)
        drawMotionMarks(&context, canvas: canvas, action: action, phase: phase)
        switch action {
        case .activity:
            drawActivity(&context, canvas: canvas, phase: phase)
        case .computer:
            drawComputer(&context, canvas: canvas, phase: phase)
        case .reading:
            drawReading(&context, canvas: canvas, phase: phase)
        case .hobby:
            drawHobby(&context, canvas: canvas, phase: phase)
        case .sleeping:
            drawSleeping(&context, canvas: canvas, phase: phase)
        case .movement:
            drawMovement(&context, canvas: canvas, phase: phase)
        case .eating:
            drawEating(&context, canvas: canvas, phase: phase)
        case .exercise:
            drawExercise(&context, canvas: canvas, phase: phase)
        case .unconfirmed:
            drawUnconfirmed(&context, canvas: canvas, phase: phase)
        case .walking:
            drawWalking(&context, canvas: canvas, phase: phase)
        case .running:
            drawRunning(&context, canvas: canvas, phase: phase)
        case .car:
            drawCar(&context, canvas: canvas, phase: phase)
        case .subway:
            drawSubway(&context, canvas: canvas, phase: phase)
        case .privateVehicle:
            drawPrivateVehicle(&context, canvas: canvas, phase: phase)
        case .bus:
            drawBus(&context, canvas: canvas, phase: phase)
        case .ship:
            drawShip(&context, canvas: canvas, phase: phase)
        case .airplane:
            drawAirplane(&context, canvas: canvas, phase: phase)
        case .cycling:
            drawCycling(&context, canvas: canvas, phase: phase)
        }
    }

    private static func stroke(
        _ context: inout GraphicsContext,
        _ points: [CGPoint],
        color: Color = accent,
        width: CGFloat = MapHomeStickmanStyle.personStrokeWidth
    ) {
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: width,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private static func fillCircle(
        _ context: inout GraphicsContext,
        _ canvas: MapHomeStickmanCanvas,
        x: CGFloat,
        y: CGFloat,
        radius: CGFloat,
        color: Color = accent
    ) {
        context.fill(
            Path(ellipseIn: canvas.rect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .color(color)
        )
    }

    private enum Face {
        case calm
        case focused
        case happy
        case sleepy
    }

    private static func drawGroundShadow(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        action: MapHomeStickmanAction,
        phase: Int
    ) {
        let breathing = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase)) * 0.8
        let y: CGFloat = switch action {
        case .sleeping: 48
        case .car, .subway, .bus, .cycling: 49
        default: 51
        }
        let width: CGFloat = switch action {
        case .sleeping: 42
        case .subway: 55
        case .car, .bus: 43
        case .cycling: 35
        default: 24
        }
        context.fill(
            Path(ellipseIn: canvas.rect(
                x: 32 - width / 2 + breathing,
                y: y,
                width: width,
                height: 3
            )),
            with: .color(.tpInk.opacity(0.10))
        )
    }

    private static func drawHead(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        x: CGFloat,
        y: CGFloat,
        radius: CGFloat,
        face: Face = .happy
    ) {
        let head = Path(ellipseIn: canvas.rect(
            x: x - radius,
            y: y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.fill(head, with: .color(deepPink))
        context.stroke(
            head,
            with: .color(deepPink),
            style: StrokeStyle(
                lineWidth: MapHomeStickmanStyle.personStrokeWidth * canvas.scale,
                lineCap: .round,
                lineJoin: .round
            )
        )

        let eyeY = y - radius * 0.12
        switch face {
        case .sleepy:
            stroke(&context, [canvas.point(x - radius * 0.42, eyeY), canvas.point(x - radius * 0.08, eyeY + 0.4)], color: faceLine, width: 0.8)
            stroke(&context, [canvas.point(x + radius * 0.08, eyeY + 0.4), canvas.point(x + radius * 0.42, eyeY)], color: faceLine, width: 0.8)
        default:
            fillCircle(&context, canvas, x: x - radius * 0.35, y: eyeY, radius: max(0.45, radius * 0.14), color: faceLine)
            fillCircle(&context, canvas, x: x + radius * 0.35, y: eyeY, radius: max(0.45, radius * 0.14), color: faceLine)
        }

        var mouth = Path()
        if face == .focused {
            mouth.move(to: canvas.point(x - radius * 0.35, y + radius * 0.48))
            mouth.addLine(to: canvas.point(x + radius * 0.35, y + radius * 0.48))
        } else {
            mouth.move(to: canvas.point(x - radius * 0.46, y + radius * 0.34))
            mouth.addQuadCurve(
                to: canvas.point(x + radius * 0.46, y + radius * 0.34),
                control: canvas.point(x, y + radius * 0.82)
            )
        }
        context.stroke(
            mouth,
            with: .color(faceLine),
            style: StrokeStyle(
                lineWidth: 0.8 * canvas.scale,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private static func outlineRect(
        _ context: inout GraphicsContext,
        _ canvas: MapHomeStickmanCanvas,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        radius: CGFloat = 2,
        fillColor: Color = fill
    ) {
        let path = Path(
            roundedRect: canvas.rect(x: x, y: y, width: width, height: height),
            cornerRadius: radius * canvas.scale
        )
        context.fill(path, with: .color(fillColor))
        context.stroke(
            path,
            with: .color(propLine),
            style: StrokeStyle(
                lineWidth: 1.2 * canvas.scale,
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private static func drawMotionMarks(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        action: MapHomeStickmanAction,
        phase: Int
    ) {
        let fast = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase))
        let slow = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        let markColor = accent.opacity(0.68)
        switch action {
        case .movement, .walking, .running, .cycling:
            stroke(
                &context,
                [canvas.point(4, 25 + fast * 2), canvas.point(11, 25 + fast * 2)],
                color: markColor,
                width: 1.2
            )
            stroke(
                &context,
                [canvas.point(53, 30 - fast * 2), canvas.point(60, 30 - fast * 2)],
                color: markColor,
                width: 1.2
            )
        case .activity, .computer, .reading, .hobby, .eating, .exercise:
            stroke(
                &context,
                [canvas.point(4, 34 + slow * 2), canvas.point(10, 34 + slow * 2)],
                color: markColor,
                width: 1.2
            )
            stroke(
                &context,
                [canvas.point(54, 24 - fast * 2), canvas.point(60, 24 - fast * 2)],
                color: markColor,
                width: 1.2
            )
        case .car, .privateVehicle, .bus, .subway, .ship, .airplane:
            stroke(
                &context,
                [canvas.point(3, 49 + slow), canvas.point(11, 49 + slow)],
                color: markColor,
                width: 1.2
            )
            stroke(
                &context,
                [canvas.point(53, 51 - slow), canvas.point(61, 51 - slow)],
                color: markColor,
                width: 1.2
            )
        case .sleeping, .unconfirmed:
            break
        }
    }

    private static func drawWalking(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let swing = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        let bob = phase.isMultiple(of: 2) ? -1.2 : 0
        drawHead(&context, canvas: canvas, x: 32, y: 10 + bob, radius: 3.4)
        stroke(&context, [canvas.point(32, 13.5 + bob), canvas.point(32, 31 + bob)])
        stroke(&context, [
            canvas.point(32, 19 + bob),
            canvas.point(23 - swing * 7, 25 + bob),
        ])
        stroke(&context, [
            canvas.point(32, 19 + bob),
            canvas.point(41 + swing * 7, 25 + bob),
        ])
        stroke(&context, [
            canvas.point(32, 31 + bob),
            canvas.point(24 + swing * 7, 45),
        ])
        stroke(&context, [
            canvas.point(32, 31 + bob),
            canvas.point(40 - swing * 7, 45),
        ])
    }

    private static func drawRunning(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let stride = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        let lift = phase.isMultiple(of: 2) ? -2.4 : 0
        drawHead(&context, canvas: canvas, x: 36, y: 9 + lift, radius: 3.4, face: .focused)
        stroke(&context, [canvas.point(34, 12.5 + lift), canvas.point(28, 29 + lift)])
        stroke(&context, [canvas.point(31, 18 + lift), canvas.point(18 - stride * 8, 15 + lift)])
        stroke(&context, [canvas.point(31, 18 + lift), canvas.point(44 + stride * 7, 25 + lift)])
        stroke(&context, [canvas.point(28, 29 + lift), canvas.point(15 + stride * 10, 39 + lift)])
        stroke(&context, [canvas.point(28, 29 + lift), canvas.point(45 - stride * 9, 43 + lift)])
        stroke(&context, [canvas.point(4, 22), canvas.point(13, 22)], color: deepPink, width: 1)
        stroke(&context, [canvas.point(7, 29), canvas.point(16, 29)], color: deepPink, width: 1)
    }

    private static func drawActivity(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let swing = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        let bob = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase))
        drawHead(&context, canvas: canvas, x: 32, y: 10 + bob * 0.5, radius: 3.4)
        stroke(&context, [canvas.point(32, 13.5 + bob * 0.5), canvas.point(32, 31 + bob)])
        stroke(&context, [canvas.point(32, 19), canvas.point(23 - swing * 4, 25)])
        stroke(&context, [canvas.point(32, 19), canvas.point(42 + swing * 4, 23)])
        stroke(&context, [canvas.point(32, 31 + bob), canvas.point(25 + swing * 3, 45)])
        stroke(&context, [canvas.point(32, 31 + bob), canvas.point(40 - swing * 3, 45)])
    }

    private static func drawMovement(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let swing = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        drawHead(&context, canvas: canvas, x: 32 + swing * 0.8, y: 9, radius: 3.4)
        stroke(&context, [canvas.point(32, 12.5), canvas.point(29, 29)])
        stroke(&context, [canvas.point(30, 18), canvas.point(20 - swing * 5, 15)])
        stroke(&context, [canvas.point(30, 18), canvas.point(43 + swing * 5, 25)])
        stroke(&context, [canvas.point(29, 29), canvas.point(18 + swing * 7, 43)])
        stroke(&context, [canvas.point(29, 29), canvas.point(43 - swing * 7, 39)])
        stroke(&context, [canvas.point(9, 12), canvas.point(15, 12)], color: deepPink, width: 1)
        stroke(&context, [canvas.point(49, 17), canvas.point(56, 17)], color: deepPink, width: 1)
    }

    private static func drawExercise(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let lift = CGFloat(MapHomeStickmanAnimationEngine.pulse(for: phase)) * 3
        drawHead(&context, canvas: canvas, x: 32, y: 8 - lift * 0.3, radius: 3.4)
        stroke(&context, [canvas.point(32, 11.5 - lift * 0.3), canvas.point(32, 28 - lift)])
        stroke(&context, [canvas.point(32, 17), canvas.point(20, 9 - lift)])
        stroke(&context, [canvas.point(32, 17), canvas.point(44, 9 - lift)])
        stroke(&context, [canvas.point(32, 28 - lift), canvas.point(23, 43)])
        stroke(&context, [canvas.point(32, 28 - lift), canvas.point(41, 43)])
        stroke(&context, [canvas.point(18, 7 - lift), canvas.point(22, 7 - lift)], color: deepPink, width: 1)
        stroke(&context, [canvas.point(42, 7 - lift), canvas.point(46, 7 - lift)], color: deepPink, width: 1)
    }

    private static func drawHobby(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let sway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        drawHead(&context, canvas: canvas, x: 27, y: 12, radius: 3.3)
        stroke(&context, [canvas.point(27, 15.5), canvas.point(29, 30)])
        stroke(&context, [canvas.point(29, 21), canvas.point(18, 27 + sway * 2)])
        stroke(&context, [canvas.point(29, 21), canvas.point(39, 24 - sway * 2)])
        stroke(&context, [canvas.point(29, 30), canvas.point(22, 42)])
        stroke(&context, [canvas.point(29, 30), canvas.point(37, 42)])
        drawMusicNote(&context, canvas: canvas, x: 45 + sway * 2, y: 17, scale: 1, phase: phase)
        drawMusicNote(&context, canvas: canvas, x: 54 - sway * 2, y: 27, scale: 0.8, phase: phase + 3)
    }

    private static func drawUnconfirmed(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let lift = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 1.5
        drawHead(&context, canvas: canvas, x: 32, y: 10, radius: 3.4, face: .focused)
        stroke(&context, [canvas.point(32, 13.5), canvas.point(32, 31)])
        stroke(&context, [canvas.point(32, 19), canvas.point(24, 27)])
        stroke(&context, [canvas.point(32, 19), canvas.point(40, 27)])
        stroke(&context, [canvas.point(32, 31), canvas.point(27, 45)])
        stroke(&context, [canvas.point(32, 31), canvas.point(37, 45)])
        drawQuestionMark(&context, canvas: canvas, x: 49, y: 13 + lift, phase: phase)
    }

    private static func drawComputer(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        drawDesk(&context, canvas: canvas)
        outlineRect(&context, canvas, x: 36, y: 18, width: 14, height: 9, radius: 1)
        stroke(&context, [canvas.point(36, 28), canvas.point(43, 30), canvas.point(51, 28)], color: propLine)
        stroke(&context, [canvas.point(38, 28.5), canvas.point(48, 28.5)], color: propLine, width: 1)
        let reach = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 1.5
        drawHead(&context, canvas: canvas, x: 21, y: 15, radius: 3.3, face: .focused)
        stroke(&context, [canvas.point(21, 18.5), canvas.point(21, 30)])
        stroke(&context, [canvas.point(21, 22), canvas.point(30, 31)])
        stroke(&context, [canvas.point(21, 22), canvas.point(35 + reach, 34)])
        stroke(&context, [canvas.point(21, 30), canvas.point(29, 38)])
        stroke(&context, [canvas.point(29, 38), canvas.point(36, 38)])
        stroke(&context, [canvas.point(21, 30), canvas.point(25, 38)])
    }

    private static func drawReading(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        drawDesk(&context, canvas: canvas)
        stroke(&context, [canvas.point(36, 31), canvas.point(43, 28), canvas.point(50, 31)], color: propLine)
        stroke(&context, [canvas.point(43, 28), canvas.point(43, 36)], color: propLine)
        let tilt = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 1.4
        drawHead(&context, canvas: canvas, x: 21 + tilt, y: 15, radius: 3.3, face: .focused)
        stroke(&context, [canvas.point(21, 18.5), canvas.point(22, 30)])
        stroke(&context, [canvas.point(22, 22), canvas.point(35, 31)])
        stroke(&context, [canvas.point(22, 22), canvas.point(37, 30)])
        stroke(&context, [canvas.point(22, 30), canvas.point(29, 38)])
        stroke(&context, [canvas.point(29, 38), canvas.point(36, 38)])
        stroke(&context, [canvas.point(22, 30), canvas.point(26, 38)])
    }

    private static func drawDesk(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas
    ) {
        stroke(&context, [canvas.point(10, 38), canvas.point(53, 38)], color: propLine, width: 1.2)
        stroke(&context, [canvas.point(14, 38), canvas.point(14, 49)], color: propLine)
        stroke(&context, [canvas.point(48, 38), canvas.point(48, 49)], color: propLine)
        stroke(&context, [canvas.point(19, 35), canvas.point(31, 35)], color: propLine)
    }

    private static func drawSleeping(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        outlineRect(&context, canvas, x: 9, y: 31, width: 48, height: 12, radius: 3)
        stroke(&context, [canvas.point(12, 43), canvas.point(12, 49)], color: propLine)
        stroke(&context, [canvas.point(53, 43), canvas.point(53, 49)], color: propLine)
        outlineRect(&context, canvas, x: 13, y: 27, width: 11, height: 6, radius: 2)
        drawHead(&context, canvas: canvas, x: 25, y: 27, radius: 3.2, face: .sleepy)
        stroke(&context, [canvas.point(28, 27), canvas.point(43, 27)], color: propLine)
        stroke(&context, [canvas.point(43, 27), canvas.point(50, 34)], color: propLine)
        let drift = CGFloat(phase % 4) * 0.5
        drawZ(&context, canvas: canvas, x: 43, y: 19 - drift, size: 4)
        drawZ(&context, canvas: canvas, x: 51, y: 10 - drift * 1.5, size: 5)
    }

    private static func drawZ(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        x: CGFloat,
        y: CGFloat,
        size: CGFloat
    ) {
        stroke(&context, [
            canvas.point(x, y),
            canvas.point(x + size, y),
            canvas.point(x, y + size),
            canvas.point(x + size, y + size),
        ], color: propLine, width: 1.2)
    }

    private static func drawMusicNote(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        x: CGFloat,
        y: CGFloat,
        scale: CGFloat,
        phase: Int
    ) {
        let bounce = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase)) * 1.5
        stroke(&context, [canvas.point(x + 3 * scale, y + bounce), canvas.point(x + 3 * scale, y + 9 * scale + bounce)], color: propLine, width: 1.2)
        stroke(&context, [canvas.point(x + 3 * scale, y + bounce), canvas.point(x + 7 * scale, y - 1 * scale + bounce)], color: propLine, width: 1.2)
        fillCircle(&context, canvas, x: x + 1.5 * scale, y: y + 9 * scale + bounce, radius: 1.8 * scale, color: propLine)
    }

    private static func drawQuestionMark(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        x: CGFloat,
        y: CGFloat,
        phase: Int
    ) {
        let lift = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 1.5
        var question = Path()
        question.move(to: canvas.point(x - 3, y + lift))
        question.addQuadCurve(
            to: canvas.point(x + 2, y + 4 + lift),
            control: canvas.point(x + 3, y - 2 + lift)
        )
        question.addQuadCurve(
            to: canvas.point(x - 1, y + 8 + lift),
            control: canvas.point(x + 2, y + 7 + lift)
        )
        context.stroke(question, with: .color(propLine), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        fillCircle(&context, canvas, x: x - 1, y: y + 12 + lift, radius: 1, color: propLine)
    }

    private static func drawCar(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        outlineRect(&context, canvas, x: 8, y: 31, width: 48, height: 13, radius: 4)
        stroke(&context, [canvas.point(17, 31), canvas.point(24, 22), canvas.point(44, 22), canvas.point(51, 31)], color: propLine)
        stroke(&context, [canvas.point(25, 23), canvas.point(25, 31), canvas.point(42, 31), canvas.point(42, 23)], color: propLine)
        fillCircle(&context, canvas, x: 19, y: 45, radius: 4, color: propLine)
        fillCircle(&context, canvas, x: 46, y: 45, radius: 4, color: propLine)
        drawHead(&context, canvas: canvas, x: 33, y: 26, radius: 2.4, face: .focused)
        stroke(&context, [canvas.point(33, 28.5), canvas.point(33, 32)], color: deepPink)
        let bounce = phase.isMultiple(of: 2) ? -0.5 : 0.5
        stroke(&context, [canvas.point(33, 30), canvas.point(38, 33 + bounce)], color: deepPink)
    }

    private static func drawPrivateVehicle(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let turn = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        outlineRect(&context, canvas, x: 8, y: 32, width: 48, height: 11, radius: 3)
        stroke(&context, [canvas.point(17, 32), canvas.point(23, 25), canvas.point(43, 25), canvas.point(51, 32)], color: propLine)
        stroke(&context, [canvas.point(26, 26), canvas.point(26, 32), canvas.point(41, 32), canvas.point(41, 26)], color: propLine)
        fillCircle(&context, canvas, x: 19, y: 44, radius: 3.5, color: propLine)
        fillCircle(&context, canvas, x: 46, y: 44, radius: 3.5, color: propLine)
        drawHead(&context, canvas: canvas, x: 34, y: 28, radius: 2.4, face: .focused)
        stroke(&context, [canvas.point(34, 30.5), canvas.point(34, 34)], color: deepPink)
        stroke(&context, [canvas.point(34, 32), canvas.point(39 + turn, 34)], color: deepPink)
        stroke(&context, [canvas.point(29, 36), canvas.point(39, 36)], color: propLine, width: 1)
    }

    private static func drawShip(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let sway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        var hull = Path()
        hull.move(to: canvas.point(8, 35 + sway))
        hull.addLine(to: canvas.point(55, 35 + sway))
        hull.addLine(to: canvas.point(48, 44 + sway))
        hull.addLine(to: canvas.point(16, 44 + sway))
        hull.closeSubpath()
        context.fill(hull, with: .color(propFill))
        context.stroke(hull, with: .color(propLine), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        stroke(&context, [canvas.point(29, 35 + sway), canvas.point(29, 21 + sway)], color: propLine)
        stroke(&context, [canvas.point(29, 21 + sway), canvas.point(42, 30 + sway)], color: propLine)
        drawHead(&context, canvas: canvas, x: 25, y: 27 + sway, radius: 2.4, face: .focused)
        stroke(&context, [canvas.point(25, 29.5 + sway), canvas.point(25, 35 + sway)], color: deepPink)
        stroke(&context, [canvas.point(25, 31 + sway), canvas.point(20, 34 + sway)], color: deepPink)
        stroke(&context, [canvas.point(25, 31 + sway), canvas.point(30, 34 + sway)], color: deepPink)
        stroke(&context, [canvas.point(5, 49), canvas.point(19, 49 + sway)], color: propLine, width: 1)
        stroke(&context, [canvas.point(40, 49 + sway), canvas.point(57, 49)], color: propLine, width: 1)
    }

    private static func drawAirplane(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let tilt = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 1.5
        outlineRect(&context, canvas, x: 16, y: 26 + tilt, width: 37, height: 9, radius: 4)
        stroke(&context, [canvas.point(25, 26 + tilt), canvas.point(19, 19 + tilt), canvas.point(23, 19 + tilt), canvas.point(31, 26 + tilt)], color: propLine)
        stroke(&context, [canvas.point(40, 35 + tilt), canvas.point(44, 42 + tilt), canvas.point(47, 42 + tilt), canvas.point(48, 35 + tilt)], color: propLine)
        stroke(&context, [canvas.point(53, 28 + tilt), canvas.point(60, 31 + tilt), canvas.point(53, 33 + tilt)], color: propLine)
        drawHead(&context, canvas: canvas, x: 31, y: 30 + tilt, radius: 2.2, face: .focused)
        stroke(&context, [canvas.point(31, 32.5 + tilt), canvas.point(31, 35 + tilt)], color: deepPink)
        stroke(&context, [canvas.point(31, 34 + tilt), canvas.point(35, 35 + tilt)], color: deepPink)
        stroke(&context, [canvas.point(5, 20 - tilt), canvas.point(12, 20 - tilt)], color: propLine, width: 1)
        stroke(&context, [canvas.point(8, 43 + tilt), canvas.point(15, 43 + tilt)], color: propLine, width: 1)
    }

    private static func drawSubway(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        outlineRect(&context, canvas, x: 4, y: 22, width: 28, height: 18, radius: 3)
        outlineRect(&context, canvas, x: 32, y: 22, width: 28, height: 18, radius: 3)
        stroke(&context, [canvas.point(32, 29), canvas.point(32, 34)], color: propLine)
        for x in [8.0, 17.0, 36.0, 45.0] {
            outlineRect(&context, canvas, x: x, y: 25, width: 7, height: 6, radius: 1, fillColor: .white.opacity(0.6))
        }
        fillCircle(&context, canvas, x: 11, y: 44, radius: 3.2, color: propLine)
        fillCircle(&context, canvas, x: 25, y: 44, radius: 3.2, color: propLine)
        fillCircle(&context, canvas, x: 39, y: 44, radius: 3.2, color: propLine)
        fillCircle(&context, canvas, x: 53, y: 44, radius: 3.2, color: propLine)
        let sway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 0.8
        drawHead(&context, canvas: canvas, x: 21 + sway, y: 29, radius: 2.1, face: .focused)
        stroke(&context, [canvas.point(21, 31), canvas.point(21, 36)], color: deepPink)
        stroke(&context, [canvas.point(21, 33), canvas.point(17, 36)], color: deepPink)
        stroke(&context, [canvas.point(21, 33), canvas.point(25, 36)], color: deepPink)
    }

    private static func drawBus(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        outlineRect(&context, canvas, x: 10, y: 21, width: 44, height: 22, radius: 4)
        for x in [15.0, 25.0, 35.0, 45.0] {
            outlineRect(&context, canvas, x: x, y: 25, width: 7, height: 7, radius: 1, fillColor: .white.opacity(0.6))
        }
        fillCircle(&context, canvas, x: 19, y: 46, radius: 3.5, color: propLine)
        fillCircle(&context, canvas, x: 45, y: 46, radius: 3.5, color: propLine)
        let sway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 0.7
        drawHead(&context, canvas: canvas, x: 29 + sway, y: 29, radius: 2.2, face: .focused)
        stroke(&context, [canvas.point(29, 31), canvas.point(29, 37)])
    }

    private static func drawCycling(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let swing = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        for x in [17.0, 47.0] {
            context.stroke(
                Path(ellipseIn: canvas.rect(x: x - 8, y: 30, width: 16, height: 16)),
                with: .color(propLine),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
            )
        }
        stroke(&context, [canvas.point(17, 38), canvas.point(29, 29), canvas.point(38, 38), canvas.point(17, 38), canvas.point(47, 38)], color: propLine)
        stroke(&context, [canvas.point(29, 29), canvas.point(34, 26)], color: propLine)
        stroke(&context, [canvas.point(34, 26), canvas.point(39, 29)], color: propLine)
        drawHead(&context, canvas: canvas, x: 30, y: 14, radius: 3.1, face: .happy)
        stroke(&context, [canvas.point(30, 17.5), canvas.point(29, 27)])
        stroke(&context, [canvas.point(29, 21), canvas.point(37, 27)])
        stroke(&context, [canvas.point(29, 27), canvas.point(24 + swing * 5, 37)])
        stroke(&context, [canvas.point(29, 27), canvas.point(36 - swing * 5, 37)])
    }

    private static func drawEating(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        stroke(&context, [canvas.point(10, 38), canvas.point(54, 38)], color: propLine, width: 1.2)
        stroke(&context, [canvas.point(14, 38), canvas.point(14, 49)], color: propLine)
        stroke(&context, [canvas.point(50, 38), canvas.point(50, 49)], color: propLine)
        let bowlLift = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase)) * 0.8
        context.fill(
            Path(ellipseIn: canvas.rect(x: 38, y: 32 + bowlLift, width: 12, height: 4)),
            with: .color(propFill)
        )
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 38, y: 32 + bowlLift, width: 12, height: 4)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )
        stroke(&context, [canvas.point(40, 34 + bowlLift), canvas.point(41, 37 + bowlLift), canvas.point(47, 37 + bowlLift), canvas.point(49, 34 + bowlLift)], color: propLine, width: 1)
        let reach = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 3
        drawHead(&context, canvas: canvas, x: 22, y: 15, radius: 3.3, face: .happy)
        stroke(&context, [canvas.point(22, 18.5), canvas.point(22, 30)])
        stroke(&context, [canvas.point(22, 22), canvas.point(31 + reach, 25)])
        stroke(&context, [canvas.point(31 + reach, 25), canvas.point(39, 33 + bowlLift)])
        stroke(&context, [canvas.point(22, 22), canvas.point(16, 30)])
        stroke(&context, [canvas.point(22, 30), canvas.point(29, 38)])
        stroke(&context, [canvas.point(22, 30), canvas.point(26, 38)])
        let forkSway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase + 2)) * 2
        stroke(&context, [canvas.point(53 + forkSway, 27), canvas.point(53 + forkSway, 35)], color: propLine, width: 1)
        stroke(&context, [canvas.point(51.5 + forkSway, 27), canvas.point(51.5 + forkSway, 30)], color: propLine, width: 1)
        stroke(&context, [canvas.point(53 + forkSway, 27), canvas.point(53 + forkSway, 30)], color: propLine, width: 1)
        stroke(&context, [canvas.point(54.5 + forkSway, 27), canvas.point(54.5 + forkSway, 30)], color: propLine, width: 1)
        let spoonSway = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase + 1)) * 1.5
        stroke(&context, [canvas.point(58 + spoonSway, 29), canvas.point(58 + spoonSway, 35)], color: propLine, width: 1)
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 56.7 + spoonSway, y: 25, width: 2.6, height: 4)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1 * canvas.scale)
        )
    }
}
