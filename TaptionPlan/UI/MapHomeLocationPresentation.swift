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
        readings: [SensorReading] = [],
        sleepSessions: [SleepSession] = []
    ) -> MapHomeStickmanAction {
        let activeActuals = actuals.compactMap { actual -> (ActualRecord, MapHomeStickmanAction)? in
            guard active(actual, at: date),
                  let action = action(for: actual) else { return nil }
            return (actual, action)
        }
        let hasExplicitOverride = actuals.contains {
            active($0, at: date)
                && ($0.manuallyCorrected || $0.source == .manual)
        }
        if !hasExplicitOverride,
           hasAppleWatchConfirmedSleep(
               at: date,
               actuals: actuals,
               sleepSessions: sleepSessions
           ) {
            return .sleeping
        }

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

    static func hasAppleWatchConfirmedSleep(
        at date: Date,
        actuals: [ActualRecord],
        sleepSessions: [SleepSession]
    ) -> Bool {
        guard !actuals.contains(where: {
            active($0, at: date)
                && ($0.manuallyCorrected || $0.source == .manual)
        }) else {
            return false
        }
        if actuals.contains(where: {
            active($0, at: date)
                && $0.source == .appleWatch
                && action(for: $0) == .sleeping
        }) {
            return true
        }
        return sleepSessions.contains {
            $0.isAppleWatchConfirmed && $0.span.contains(date)
        }
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
            ("movement.privatevehicle", .car),
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
            return .car
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
            return .car
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
    static let frameDuration = TaptionLiveActivityStickmanAnimation.frameDuration
    static let phaseCount = TaptionLiveActivityStickmanAnimation.frameCount

    static func phase(at date: Date, reducesMotion: Bool = false) -> Int {
        TaptionLiveActivityStickmanAnimation.frameIndex(
            at: date.timeIntervalSinceReferenceDate,
            isAnimating: !reducesMotion
        )
    }

    static func phase(for progress: Double) -> Int {
        guard progress.isFinite else { return 0 }
        let normalized = min(max(progress, 0), 1)
        return min(
            phaseCount - 1,
            Int((normalized * Double(phaseCount)).rounded(.down))
        )
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
    static let inkHex = TaptionLiveActivityStickmanStyle.inkHex
    static let headFillHex = TaptionLiveActivityStickmanStyle.headFillHex
    static let personStrokeWidth = TaptionLiveActivityStickmanStyle.personStrokeWidth
}

enum MapHomeStickmanRoutePhase {
    case actual
    case forecast

    var color: Color {
        Color(hex: self == .actual ? "#458B88" : "#C65D4D")
    }
}

struct MapHomeStickmanMarker: View {
    static let size = CGSize(width: 36, height: 36)

    let action: MapHomeStickmanAction
    var animationPhase: Int? = nil
    var routePhase: MapHomeStickmanRoutePhase = .actual
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced
        TimelineView(
            .animation(
                minimumInterval: MapHomeStickmanAnimationEngine.frameDuration,
                paused: isStatic || animationPhase != nil
            )
        ) { context in
            Canvas { canvas, size in
                MapHomeStickmanRenderer.draw(
                    context: &canvas,
                    size: size,
                    action: action,
                    phase: isStatic
                        ? 0
                        : animationPhase
                            ?? MapHomeStickmanAnimationEngine.phase(
                                at: context.date,
                                reducesMotion: false
                            )
                )
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(hex: "#FCF9F4").opacity(0.96), in: Circle())
        .overlay { Circle().stroke(routePhase.color.opacity(0.90), lineWidth: 1.25) }
        .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
        .accessibilityHidden(true)
    }
}

struct MapHomeStickmanGlyph: View {
    let action: MapHomeStickmanAction
    var size: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        let isStatic = reduceMotion || isLuminanceReduced
        TimelineView(
            .animation(
                minimumInterval: MapHomeStickmanAnimationEngine.frameDuration,
                paused: isStatic
            )
        ) { context in
            Canvas { canvas, canvasSize in
                MapHomeStickmanRenderer.draw(
                    context: &canvas,
                    size: canvasSize,
                    action: action,
                    phase: MapHomeStickmanAnimationEngine.phase(
                        at: context.date,
                        reducesMotion: isStatic
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
    private static let ink = Color(hex: MapHomeStickmanStyle.inkHex)
    private static let headFill = Color(hex: MapHomeStickmanStyle.headFillHex)
    private static let deepPink = ink
    private static let outline = ink
    private static let bodyFill = ink
    private static let skinFill = headFill
    private static let accent = ink
    private static let line = ink
    private static let faceLine = ink
    private static let propLine = ink
    private static let propFill = Color(hex: "#FCF9F4").opacity(0.94)
    private static let fill = propFill
    private static let sceneryLeaf = Color(hex: "#B9DEC5").opacity(0.9)
    private static let sceneryTrunk = Color(hex: "#A98D7A").opacity(0.72)
    private static let sceneryCloud = Color(hex: "#D9E8FA").opacity(0.9)
    private static let sceneryGround = Color(hex: "#B7D8C1").opacity(0.78)

    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        action: MapHomeStickmanAction,
        phase: Int
    ) {
        let canvas = MapHomeStickmanCanvas(size: size)
        if action == .walking {
            drawWalkingScenery(&context, canvas: canvas, phase: phase)
        }
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
            drawCar(&context, canvas: canvas, phase: phase)
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

    private enum Viewpoint {
        case front
        case sideLeft
        case sideRight
        case diagonalLeft
        case rearRight
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
        face: Face = .happy,
        viewpoint: Viewpoint = .front,
        singing: Bool = false,
        phase: Int = 0
    ) {
        let head = Path(ellipseIn: canvas.rect(
            x: x - radius,
            y: y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        context.fill(head, with: .color(skinFill))
        context.stroke(
            head,
            with: .color(outline),
            style: StrokeStyle(
                lineWidth: 1.4 * canvas.scale,
                lineCap: .round,
                lineJoin: .round
            )
        )

        let eyeY = y - radius * 0.12
        switch viewpoint {
        case .front:
            switch face {
            case .sleepy:
                stroke(&context, [canvas.point(x - radius * 0.42, eyeY), canvas.point(x - radius * 0.08, eyeY + 0.4)], color: faceLine, width: 0.8)
                stroke(&context, [canvas.point(x + radius * 0.08, eyeY + 0.4), canvas.point(x + radius * 0.42, eyeY)], color: faceLine, width: 0.8)
            default:
                fillCircle(&context, canvas, x: x - radius * 0.35, y: eyeY, radius: max(0.45, radius * 0.14), color: faceLine)
                fillCircle(&context, canvas, x: x + radius * 0.35, y: eyeY, radius: max(0.45, radius * 0.14), color: faceLine)
            }
        case .sideLeft, .sideRight:
            let direction: CGFloat = viewpoint == .sideLeft ? -1 : 1
            if face == .sleepy {
                stroke(&context, [canvas.point(x + direction * radius * 0.38, eyeY), canvas.point(x + direction * radius * 0.06, eyeY + 0.35)], color: faceLine, width: 0.8)
            } else {
                fillCircle(&context, canvas, x: x + direction * radius * 0.28, y: eyeY, radius: max(0.45, radius * 0.14), color: faceLine)
            }
            stroke(&context, [canvas.point(x + direction * radius * 0.55, eyeY + 0.1), canvas.point(x + direction * radius * 0.82, y + radius * 0.04)], color: faceLine, width: 0.7)
        case .diagonalLeft:
            if face == .sleepy {
                stroke(&context, [canvas.point(x - radius * 0.48, eyeY), canvas.point(x - radius * 0.15, eyeY + 0.35)], color: faceLine, width: 0.8)
                stroke(&context, [canvas.point(x + radius * 0.02, eyeY + 0.35), canvas.point(x + radius * 0.28, eyeY)], color: faceLine, width: 0.8)
            } else {
                fillCircle(&context, canvas, x: x - radius * 0.38, y: eyeY, radius: max(0.45, radius * 0.14), color: faceLine)
                fillCircle(&context, canvas, x: x + radius * 0.15, y: eyeY + 0.15, radius: max(0.4, radius * 0.12), color: faceLine)
            }
            stroke(&context, [canvas.point(x - radius * 0.5, eyeY + 0.25), canvas.point(x - radius * 0.78, y + radius * 0.08)], color: faceLine, width: 0.7)
        case .rearRight:
            var hair = Path()
            hair.move(to: canvas.point(x - radius * 0.72, y - radius * 0.12))
            hair.addQuadCurve(
                to: canvas.point(x + radius * 0.65, y - radius * 0.28),
                control: canvas.point(x + radius * 0.1, y - radius * 0.98)
            )
            context.stroke(hair, with: .color(outline), style: StrokeStyle(lineWidth: 1.1 * canvas.scale, lineCap: .round))
            stroke(&context, [canvas.point(x + radius * 0.52, y + radius * 0.02), canvas.point(x + radius * 0.72, y + radius * 0.12)], color: outline, width: 0.7)
        }

        guard viewpoint != .rearRight else { return }
        let openMouth = singing && phase % 4 < 2
        let direction: CGFloat = switch viewpoint {
        case .sideLeft, .diagonalLeft: -1
        default: 1
        }
        if openMouth {
            context.fill(
                Path(ellipseIn: canvas.rect(
                    x: x + direction * radius * 0.22 - radius * 0.3,
                    y: y + radius * 0.2,
                    width: radius * 0.6,
                    height: radius * 0.5
                )),
                with: .color(faceLine)
            )
            return
        }

        var mouth = Path()
        if face == .focused {
            mouth.move(to: canvas.point(x + direction * radius * 0.08, y + radius * 0.48))
            mouth.addLine(to: canvas.point(x + direction * radius * 0.55, y + radius * 0.48))
        } else {
            mouth.move(to: canvas.point(x - direction * radius * 0.05, y + radius * 0.34))
            mouth.addQuadCurve(
                to: canvas.point(x + direction * radius * 0.7, y + radius * 0.34),
                control: canvas.point(x + direction * radius * 0.32, y + radius * 0.82)
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

    private static func drawPerson(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        action: MapHomeStickmanAction,
        phase: Int,
        viewpoint: Viewpoint = .front
    ) {
        let pose = TaptionStickmanPoseEngine.pose(
            action: TaptionStickmanPoseAction(rawValue: action.rawValue) ?? .activity,
            phase: phase,
            phaseCount: MapHomeStickmanAnimationEngine.phaseCount
        )
        func point(_ value: TaptionStickmanPoint) -> CGPoint {
            canvas.point(CGFloat(value.x), CGFloat(value.y))
        }

        func limb(_ points: [CGPoint], prominent: Bool = true) {
            stroke(
                &context,
                points,
                color: ink.opacity(prominent ? 1 : 0.72),
                width: prominent
                    ? MapHomeStickmanStyle.personStrokeWidth
                    : MapHomeStickmanStyle.personStrokeWidth * 0.82
            )
        }

        let leftNear = viewpoint == .sideLeft || viewpoint == .diagonalLeft
        let rightNear = viewpoint == .sideRight || viewpoint == .rearRight
        limb([point(pose.leftHip), point(pose.leftKnee), point(pose.leftFoot)], prominent: viewpoint == .front || leftNear)
        limb([point(pose.rightHip), point(pose.rightKnee), point(pose.rightFoot)], prominent: viewpoint == .front || rightNear)
        limb([point(pose.leftShoulder), point(pose.leftElbow), point(pose.leftHand)], prominent: viewpoint == .front || leftNear)
        limb([point(pose.rightShoulder), point(pose.rightElbow), point(pose.rightHand)], prominent: viewpoint == .front || rightNear)
        limb([point(pose.neck), point(pose.head)])
        limb([point(pose.neck), point(pose.leftShoulder)])
        limb([point(pose.neck), point(pose.rightShoulder)])
        stroke(
            &context,
            [
                point(pose.neck),
                canvas.point(
                    CGFloat((pose.leftHip.x + pose.rightHip.x) / 2),
                    CGFloat((pose.leftHip.y + pose.rightHip.y) / 2)
                ),
            ],
            color: ink,
            width: MapHomeStickmanStyle.personStrokeWidth
        )

        for joint in [
            pose.leftShoulder,
            pose.leftElbow,
            pose.leftHip,
            pose.leftKnee,
            pose.rightShoulder,
            pose.rightElbow,
            pose.rightHip,
            pose.rightKnee,
        ] {
            fillCircle(
                &context,
                canvas,
                x: CGFloat(joint.x),
                y: CGFloat(joint.y),
                radius: 0.82,
                color: ink
            )
        }

        for joint in [pose.leftHand, pose.rightHand, pose.leftFoot, pose.rightFoot] {
            let jointPath = Path(ellipseIn: canvas.rect(
                x: CGFloat(joint.x) - 1.2,
                y: CGFloat(joint.y) - 1.2,
                width: 2.4,
                height: 2.4
            ))
            context.fill(jointPath, with: .color(headFill))
            context.stroke(
                jointPath,
                with: .color(ink),
                style: StrokeStyle(
                    lineWidth: 1.0 * canvas.scale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }

        let face: Face = switch pose.face {
        case .calm: .calm
        case .focused: .focused
        case .happy: .happy
        case .sleepy: .sleepy
        }
        drawHead(
            &context,
            canvas: canvas,
            x: CGFloat(pose.head.x),
            y: CGFloat(pose.head.y),
            radius: CGFloat(pose.headRadius),
            face: face,
            viewpoint: viewpoint,
            singing: action == .hobby,
            phase: phase
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
        drawPerson(&context, canvas: canvas, action: .walking, phase: phase, viewpoint: .sideRight)
    }

    private static func drawWalkingScenery(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let frame = TaptionStickmanWalkingSceneryAnimation.frame(
            phase: phase,
            phaseCount: MapHomeStickmanAnimationEngine.phaseCount
        )
        stroke(
            &context,
            [canvas.point(0, 48), canvas.point(64, 48)],
            color: sceneryGround,
            width: 1
        )
        for base in stride(from: -8.0, through: 72.0, by: 8.0) {
            let x = CGFloat(base - frame.groundOffset)
            stroke(
                &context,
                [canvas.point(x, 48), canvas.point(x + 3, 48)],
                color: sceneryGround,
                width: 1.4
            )
        }
        for value in frame.cloudX {
            let x = CGFloat(value)
            fillCircle(
                &context,
                canvas,
                x: x,
                y: 9,
                radius: 3.2,
                color: sceneryCloud
            )
            fillCircle(
                &context,
                canvas,
                x: x + 4,
                y: 8,
                radius: 4,
                color: sceneryCloud
            )
            fillCircle(
                &context,
                canvas,
                x: x + 8,
                y: 10,
                radius: 3,
                color: sceneryCloud
            )
        }
        for value in frame.treeX {
            let x = CGFloat(value)
            stroke(
                &context,
                [canvas.point(x, 34), canvas.point(x, 48)],
                color: sceneryTrunk,
                width: 1.4
            )
            fillCircle(
                &context,
                canvas,
                x: x,
                y: 31,
                radius: 5,
                color: sceneryLeaf
            )
            fillCircle(
                &context,
                canvas,
                x: x - 3.5,
                y: 34,
                radius: 3.5,
                color: sceneryLeaf
            )
            fillCircle(
                &context,
                canvas,
                x: x + 3.5,
                y: 34,
                radius: 3.5,
                color: sceneryLeaf
            )
        }
    }

    private static func drawRunning(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        stroke(&context, [canvas.point(4, 22), canvas.point(13, 22)], color: deepPink, width: 1)
        stroke(&context, [canvas.point(7, 29), canvas.point(16, 29)], color: deepPink, width: 1)
        drawPerson(&context, canvas: canvas, action: .running, phase: phase, viewpoint: .sideRight)
    }

    private static func drawActivity(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let normalizedPhase = ((phase % MapHomeStickmanAnimationEngine.phaseCount)
            + MapHomeStickmanAnimationEngine.phaseCount)
            % MapHomeStickmanAnimationEngine.phaseCount
        let viewpoint: Viewpoint = switch normalizedPhase {
        case 0..<4: .front
        case 4..<8: .sideLeft
        default: .sideRight
        }
        drawPerson(&context, canvas: canvas, action: .activity, phase: phase, viewpoint: viewpoint)
    }

    private static func drawMovement(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        drawPerson(&context, canvas: canvas, action: .movement, phase: phase, viewpoint: .sideRight)
    }

    private static func drawExercise(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let lift = CGFloat(MapHomeStickmanAnimationEngine.pulse(for: phase)) * 3
        stroke(&context, [canvas.point(18, 7 - lift), canvas.point(22, 7 - lift)], color: deepPink, width: 1)
        stroke(&context, [canvas.point(42, 7 - lift), canvas.point(46, 7 - lift)], color: deepPink, width: 1)
        drawPerson(&context, canvas: canvas, action: .exercise, phase: phase, viewpoint: .diagonalLeft)
    }

    private static func drawHobby(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let sway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase))
        drawMusicNote(&context, canvas: canvas, x: 45 + sway * 2, y: 17, scale: 1, phase: phase)
        drawMusicNote(&context, canvas: canvas, x: 54 - sway * 2, y: 27, scale: 0.8, phase: phase + 3)
        let microphoneSway = sway * 0.35
        context.fill(
            Path(ellipseIn: canvas.rect(x: 35 + microphoneSway, y: 16, width: 4, height: 6)),
            with: .color(propFill)
        )
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 35 + microphoneSway, y: 16, width: 4, height: 6)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1.1 * canvas.scale, lineCap: .round)
        )
        stroke(&context, [canvas.point(37 + microphoneSway, 22), canvas.point(37 + microphoneSway, 39)], color: propLine, width: 1)
        stroke(&context, [canvas.point(33, 39), canvas.point(41, 39)], color: propLine, width: 1)
        drawPerson(&context, canvas: canvas, action: .hobby, phase: phase, viewpoint: .front)
    }

    private static func drawUnconfirmed(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let lift = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 1.5
        drawQuestionMark(&context, canvas: canvas, x: 49, y: 13 + lift, phase: phase)
        drawPerson(&context, canvas: canvas, action: .unconfirmed, phase: phase, viewpoint: .front)
    }

    private static func drawComputer(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        outlineRect(&context, canvas, x: 31, y: 10, width: 29, height: 22, radius: 2)
        drawTypedText(&context, canvas: canvas, phase: phase)
        stroke(&context, [canvas.point(45.5, 32), canvas.point(45.5, 36)], color: propLine)
        stroke(&context, [canvas.point(39, 36), canvas.point(52, 36)], color: propLine, width: 1.2)
        outlineRect(&context, canvas, x: 27, y: 31, width: 16, height: 4, radius: 1, fillColor: propFill)
        for x in stride(from: 29.0, through: 41.0, by: 3.0) {
            stroke(&context, [canvas.point(x, 32.5), canvas.point(x + 1.5, 32.5)], color: propLine, width: 0.7)
        }
        drawPerson(&context, canvas: canvas, action: .computer, phase: phase, viewpoint: .rearRight)
    }

    private static func drawTypedText(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let typing = TaptionStickmanTypingAnimation.frame(
            phase: phase,
            phaseCount: MapHomeStickmanAnimationEngine.phaseCount
        )
        let startX: CGFloat = 34
        let startY: CGFloat = 15
        let unitStride: CGFloat = 3.6
        for lineIndex in typing.lineUnits.indices {
            let y = startY + CGFloat(lineIndex) * 5.5
            for unit in 0..<typing.lineUnits[lineIndex] {
                let x = startX + CGFloat(unit) * unitStride
                stroke(
                    &context,
                    [canvas.point(x, y), canvas.point(x + 2.2, y)],
                    color: propLine,
                    width: 0.8
                )
            }
        }
        if typing.cursorVisible {
            let units = typing.lineUnits[typing.activeLine]
            let x = startX + CGFloat(units) * unitStride
            let y = startY + CGFloat(typing.activeLine) * 5.5
            stroke(
                &context,
                [canvas.point(x, y - 1.5), canvas.point(x, y + 1.5)],
                color: propLine,
                width: 0.8
            )
        }
    }

    private static func drawReading(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let pageLift = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase)) * 0.8
        var leftPage = Path()
        leftPage.move(to: canvas.point(32, 28))
        leftPage.addLine(to: canvas.point(43, 25 + pageLift))
        leftPage.addLine(to: canvas.point(43, 36))
        leftPage.addLine(to: canvas.point(32, 39))
        leftPage.closeSubpath()
        var rightPage = Path()
        rightPage.move(to: canvas.point(43, 25 + pageLift))
        rightPage.addLine(to: canvas.point(55, 28))
        rightPage.addLine(to: canvas.point(54, 39))
        rightPage.addLine(to: canvas.point(43, 36))
        rightPage.closeSubpath()
        for page in [leftPage, rightPage] {
            context.fill(page, with: .color(propFill))
            context.stroke(
                page,
                with: .color(propLine),
                style: StrokeStyle(lineWidth: 1.2 * canvas.scale, lineCap: .round, lineJoin: .round)
            )
        }
        stroke(&context, [canvas.point(35, 31), canvas.point(40, 29.5)], color: propLine, width: 0.8)
        stroke(&context, [canvas.point(46, 29.5), canvas.point(51, 31)], color: propLine, width: 0.8)
        stroke(&context, [canvas.point(43, 25 + pageLift), canvas.point(43, 36)], color: propLine, width: 0.8)
        drawPerson(&context, canvas: canvas, action: .reading, phase: phase, viewpoint: .diagonalLeft)
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
        let drift = CGFloat(phase % 4) * 0.5
        stroke(&context, [canvas.point(24, 33), canvas.point(38, 32.5 + drift * 0.2), canvas.point(52, 34)], color: propLine, width: 0.8)
        drawZ(&context, canvas: canvas, x: 43, y: 19 - drift, size: 4)
        drawZ(&context, canvas: canvas, x: 51, y: 10 - drift * 1.5, size: 5)
        drawPerson(&context, canvas: canvas, action: .sleeping, phase: phase, viewpoint: .sideRight)
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
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 36, y: 29, width: 9, height: 7)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1.1 * canvas.scale, lineCap: .round)
        )
        stroke(&context, [canvas.point(40.5, 32.5), canvas.point(40.5, 35)], color: propLine, width: 0.9)
        fillCircle(&context, canvas, x: 19, y: 45, radius: 4, color: propLine)
        fillCircle(&context, canvas, x: 46, y: 45, radius: 4, color: propLine)
        drawPerson(&context, canvas: canvas, action: .car, phase: phase, viewpoint: .front)
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
        stroke(&context, [canvas.point(14, 28 + sway), canvas.point(42, 28 + sway)], color: propLine, width: 1.1)
        stroke(&context, [canvas.point(17, 28 + sway), canvas.point(17, 35 + sway)], color: propLine, width: 0.9)
        stroke(&context, [canvas.point(39, 28 + sway), canvas.point(39, 35 + sway)], color: propLine, width: 0.9)
        stroke(&context, [canvas.point(5, 49), canvas.point(19, 49 + sway)], color: propLine, width: 1)
        stroke(&context, [canvas.point(40, 49 + sway), canvas.point(57, 49)], color: propLine, width: 1)
        drawPerson(&context, canvas: canvas, action: .ship, phase: phase, viewpoint: .sideRight)
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
        outlineRect(&context, canvas, x: 24, y: 27 + tilt, width: 14, height: 7, radius: 2, fillColor: .white.opacity(0.64))
        drawWindowPassenger(&context, canvas: canvas, centerX: 31, top: 27 + tilt, bottom: 34 + tilt, phase: phase, scale: 0.9, holdingStrap: false)
        stroke(&context, [canvas.point(5, 20 - tilt), canvas.point(12, 20 - tilt)], color: propLine, width: 1)
        stroke(&context, [canvas.point(8, 43 + tilt), canvas.point(15, 43 + tilt)], color: propLine, width: 1)
    }

    private static func drawWindowPassenger(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        centerX: CGFloat,
        top: CGFloat,
        bottom: CGFloat,
        phase: Int,
        scale: CGFloat,
        holdingStrap: Bool
    ) {
        let sway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase)) * 0.45 * scale
        let headX = centerX + sway
        let headY = top + 2.1 * scale
        let headRadius = 1.25 * scale
        fillCircle(&context, canvas, x: headX, y: headY, radius: headRadius, color: skinFill)
        context.stroke(
            Path(ellipseIn: canvas.rect(
                x: headX - headRadius,
                y: headY - headRadius,
                width: headRadius * 2,
                height: headRadius * 2
            )),
            with: .color(outline),
            style: StrokeStyle(lineWidth: 0.7 * canvas.scale, lineCap: .round)
        )
        fillCircle(&context, canvas, x: headX - 0.45 * scale, y: headY, radius: 0.22 * scale, color: faceLine)
        fillCircle(&context, canvas, x: headX + 0.45 * scale, y: headY, radius: 0.22 * scale, color: faceLine)
        let shoulderY = headY + 2.1 * scale
        let footY = min(bottom - 0.4 * scale, shoulderY + 4.3 * scale)
        stroke(&context, [canvas.point(headX, shoulderY), canvas.point(headX, footY)], color: deepPink, width: 1.1 * scale)
        if holdingStrap {
            let strapX = centerX + 2.8 * scale
            stroke(&context, [canvas.point(strapX, top - 1.5 * scale), canvas.point(strapX, top + 1.3 * scale)], color: propLine, width: 0.7)
            context.stroke(
                Path(ellipseIn: canvas.rect(x: strapX - 0.8 * scale, y: top + 0.8 * scale, width: 1.6 * scale, height: 1.8 * scale)),
                with: .color(propLine),
                style: StrokeStyle(lineWidth: 0.6 * canvas.scale, lineCap: .round)
            )
            stroke(&context, [canvas.point(headX - 1.4 * scale, shoulderY), canvas.point(strapX, top + 1.8 * scale)], color: deepPink, width: 0.8 * scale)
            stroke(&context, [canvas.point(headX + 1.4 * scale, shoulderY), canvas.point(strapX, top + 1.8 * scale)], color: deepPink, width: 0.8 * scale)
        } else {
            stroke(&context, [canvas.point(headX - 1.5 * scale, shoulderY), canvas.point(headX - 2.2 * scale, shoulderY + 1.8 * scale)], color: deepPink, width: 0.8 * scale)
            stroke(&context, [canvas.point(headX + 1.5 * scale, shoulderY), canvas.point(headX + 2.2 * scale, shoulderY + 1.8 * scale)], color: deepPink, width: 0.8 * scale)
        }
    }

    private static func drawSubway(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        outlineRect(&context, canvas, x: 4, y: 22, width: 28, height: 18, radius: 3)
        outlineRect(&context, canvas, x: 32, y: 22, width: 28, height: 18, radius: 3)
        stroke(&context, [canvas.point(32, 29), canvas.point(32, 34)], color: propLine)
        for x in [7.0, 18.0, 35.0, 46.0] {
            outlineRect(&context, canvas, x: x, y: 24.5, width: 9, height: 8, radius: 1.5, fillColor: .white.opacity(0.6))
        }
        drawWindowPassenger(&context, canvas: canvas, centerX: 22.5, top: 24.5, bottom: 32.5, phase: phase, scale: 1.05, holdingStrap: true)
        fillCircle(&context, canvas, x: 11, y: 44, radius: 3.2, color: propLine)
        fillCircle(&context, canvas, x: 25, y: 44, radius: 3.2, color: propLine)
        fillCircle(&context, canvas, x: 39, y: 44, radius: 3.2, color: propLine)
        fillCircle(&context, canvas, x: 53, y: 44, radius: 3.2, color: propLine)
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
        stroke(&context, [canvas.point(14, 23), canvas.point(50, 23)], color: propLine, width: 0.9)
        stroke(&context, [canvas.point(24, 23), canvas.point(24, 25.5)], color: propLine, width: 0.8)
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 23, y: 25, width: 2, height: 2.2)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 0.6 * canvas.scale, lineCap: .round)
        )
        fillCircle(&context, canvas, x: 19, y: 46, radius: 3.5, color: propLine)
        fillCircle(&context, canvas, x: 45, y: 46, radius: 3.5, color: propLine)
        drawPerson(&context, canvas: canvas, action: .bus, phase: phase, viewpoint: .sideRight)
    }

    private static func drawCycling(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
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
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 29, y: 32, width: 6, height: 6)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1 * canvas.scale, lineCap: .round)
        )
        let pedalAngle = 2 * .pi * Double(phase) / Double(MapHomeStickmanAnimationEngine.phaseCount)
        let pedalX = 32 + CGFloat(cos(pedalAngle)) * 3
        let pedalY = 35 + CGFloat(sin(pedalAngle)) * 3
        stroke(&context, [canvas.point(32, 35), canvas.point(pedalX, pedalY)], color: propLine, width: 0.9)
        stroke(&context, [canvas.point(pedalX, pedalY), canvas.point(pedalX + 2.5, pedalY)], color: propLine, width: 0.8)
        drawPerson(&context, canvas: canvas, action: .cycling, phase: phase, viewpoint: .sideRight)
    }

    private static func drawEating(
        _ context: inout GraphicsContext,
        canvas: MapHomeStickmanCanvas,
        phase: Int
    ) {
        let bowlLift = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase)) * 0.8
        stroke(&context, [canvas.point(28, 35), canvas.point(58, 35)], color: propLine, width: 1.4)
        stroke(&context, [canvas.point(31, 35), canvas.point(29, 47)], color: propLine, width: 1)
        stroke(&context, [canvas.point(54, 35), canvas.point(56, 47)], color: propLine, width: 1)
        context.fill(
            Path(ellipseIn: canvas.rect(x: 37, y: 29 + bowlLift, width: 14, height: 4)),
            with: .color(propFill)
        )
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 37, y: 29 + bowlLift, width: 14, height: 4)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )
        stroke(&context, [canvas.point(39, 31 + bowlLift), canvas.point(40, 35 + bowlLift), canvas.point(48, 35 + bowlLift), canvas.point(50, 31 + bowlLift)], color: propLine, width: 1)
        let forkSway = CGFloat(MapHomeStickmanAnimationEngine.oscillation(for: phase + 2)) * 2
        stroke(&context, [canvas.point(53 + forkSway, 24), canvas.point(53 + forkSway, 34)], color: propLine, width: 1)
        stroke(&context, [canvas.point(51.5 + forkSway, 24), canvas.point(51.5 + forkSway, 27)], color: propLine, width: 1)
        stroke(&context, [canvas.point(53 + forkSway, 24), canvas.point(53 + forkSway, 27)], color: propLine, width: 1)
        stroke(&context, [canvas.point(54.5 + forkSway, 24), canvas.point(54.5 + forkSway, 27)], color: propLine, width: 1)
        let spoonSway = CGFloat(MapHomeStickmanAnimationEngine.secondaryOscillation(for: phase + 1)) * 1.5
        stroke(&context, [canvas.point(58 + spoonSway, 26), canvas.point(58 + spoonSway, 34)], color: propLine, width: 1)
        context.stroke(
            Path(ellipseIn: canvas.rect(x: 56.7 + spoonSway, y: 22, width: 2.6, height: 4)),
            with: .color(propLine),
            style: StrokeStyle(lineWidth: 1 * canvas.scale)
        )
        drawPerson(&context, canvas: canvas, action: .eating, phase: phase, viewpoint: .diagonalLeft)
    }
}
