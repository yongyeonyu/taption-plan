import SwiftUI

/// 타임라인 세 줄의 폭. 왼쪽 장소, 가운데 대분류, 오른쪽은 비워 둔다(NLE1104A01).
/// 줄은 화면 밖까지 넓혀 그리므로(`railBleed`) 넘치는 폭은 오른쪽 줄이 받는다.
struct NLELaneWidths {
    enum Lane: Equatable {
        case gutter, place, main, right
    }

    let gutter: CGFloat
    let gap: CGFloat
    let place: CGFloat
    let main: CGFloat
    let right: CGFloat

    init(total: CGFloat, gutter: CGFloat, gap: CGFloat, overflow: CGFloat = 0) {
        self.gutter = gutter
        self.gap = gap
        let visible = max(90, total - overflow - gutter - gap * 2)
        place = max(26, (visible * 0.28).rounded())
        main = max(40, (visible * 0.44).rounded())
        right = max(26, total - gutter - gap * 2 - place - main)
    }

    var placeX: CGFloat { gutter }
    var mainX: CGFloat { placeX + place + gap }
    var rightX: CGFloat { mainX + main + gap }

    func lane(atX x: CGFloat) -> Lane {
        if x <= gutter { return .gutter }
        if x < mainX { return .place }
        return x < rightX ? .main : .right
    }
}

/// 장소 줄 한 칸. 머문 기록에서 파생한 읽기 전용 값이다.
struct NLEPlaceSegment: Identifiable, Equatable {
    enum Kind: Equatable {
        case registered, visited, transit
    }

    let id: String
    let title: String
    let startMinute: Int
    let endMinute: Int
    var kind: Kind = .visited
}

enum NLEPlaceLane {
    /// 이보다 짧은 미등록 체류는 신호 잡음으로 보고 표시하지 않는다.
    static let minimumVisitMinutes = 5
    /// 등록 지점 체류가 이 정도면 이동 클립 안에 있어도 들른 곳으로 남긴다.
    static let minimumStopMinutes = 10
    /// 같은 곳의 체류가 이 안에서 끊기면 GPS 공백으로 보고 잇는다.
    static let sameplaceJoinMinutes = 20
    /// 이보다 긴 빈 시간은 이동으로 잇지 않는다(기록이 없는 시간일 수 있다).
    static let maximumInferredTransitMinutes = 180
    /// 이어지는 이동 클립을 하나로 보는 간격.
    static let movementJoinMinutes = 5

    private struct Stay {
        var key: String
        var title: String
        var isRegistered: Bool
        var id: String
        var start: Int
        var end: Int
    }

    /// 체류를 등록 지점 위주로 정리하고, 지점 사이 이동을 "회사 → 집" 칸으로 잇는다.
    /// `movement`는 메인 줄 이동 클립의 분이다. 칸 경계가 그 클립과 맞도록 체류를 잘라 낸다.
    /// `dayOffset`은 편집기의 날 오프셋이다(어제 = −1).
    static func segments(
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace] = [],
        movement: [Range<Int>] = [],
        nearbyNames: [String: String] = [:],
        dayStart: Date,
        dayOffset: Int = 0
    ) -> [NLEPlaceSegment] {
        let shift = dayOffset * NLETrack.dayMinutes
        let dayRange = shift..<(shift + NLETrack.dayMinutes)
        let stays = resolvedStays(
            places: places, frequentPlaces: frequentPlaces, nearbyNames: nearbyNames, dayStart: dayStart, shift: shift
        )
        let joinedMovement = merged(movement.compactMap { span -> Range<Int>? in
            let clamped = span.clamped(to: dayRange)
            return clamped.isEmpty ? nil : clamped
        })
        // 이동 클립 안에 오래 머문 등록 지점은 이동을 둘로 나눈다.
        let stops = stays.filter { stay in
            stay.isRegistered && stay.end - stay.start >= minimumStopMinutes
                && joinedMovement.contains { $0.lowerBound <= stay.start && stay.end <= $0.upperBound }
        }
        let moves = joinedMovement.flatMap { span in
            stops.reduce([span]) { pieces, stop in
                pieces.flatMap { subtract(stop.start..<stop.end, from: $0) }
            }
        }
        let visible = joinSamePlace(
            stays.flatMap { stay -> [Stay] in
                moves.reduce([stay.start..<stay.end]) { pieces, move in
                    pieces.flatMap { subtract(move, from: $0) }
                }
                .map { var piece = stay; piece.start = $0.lowerBound; piece.end = $0.upperBound; return piece }
            }
            .filter { $0.isRegistered ? $0.end > $0.start : $0.end - $0.start >= minimumVisitMinutes },
            moves: moves
        )
        return timeline(stays: visible, moves: moves)
    }

    /// 지도에서 이름을 찾아야 하는 미등록 체류의 좌표. 오래 머문 곳부터 준다.
    static func pointsNeedingNames(places: [PlaceStay], frequentPlaces: [FrequentPlace]) -> [GeoPoint] {
        var seen = Set<String>()
        return places
            .filter { registeredName(for: $0, frequentPlaces: frequentPlaces) == nil }
            .filter { $0.span.duration >= TimeInterval(minimumVisitMinutes * 60) }
            .sorted { $0.span.duration > $1.span.duration }
            .compactMap(\.point)
            .filter { seen.insert(nameKey(for: $0)).inserted }
    }

    /// 지도 이름 캐시의 열쇠. 약 50m 칸으로 묶어 가까운 체류가 같은 검색을 되풀이하지 않게 한다.
    static func nameKey(for point: GeoPoint) -> String {
        let cell = 0.0005
        return "\((point.latitude / cell).rounded()):\((point.longitude / cell).rounded())"
    }

    /// 등록 지점이면 그 이름. 확정 시간보다 짧게 들른 체류도 반경 안이면 등록 지점으로 본다.
    static func registeredName(for stay: PlaceStay, frequentPlaces: [FrequentPlace]) -> (key: String, name: String)? {
        if stay.isRegisteredFrequentPlace { return (stay.placeKey, stay.displayName) }
        guard let point = stay.point else { return nil }
        let nearest = frequentPlaces.compactMap { place -> (FrequentPlace, Double)? in
            guard let center = place.point else { return nil }
            let ratio = distanceMeters(point, center) / max(place.radiusMeters, 1)
            return ratio <= 1 ? (place, ratio) : nil
        }
        .min { $0.1 < $1.1 }
        return nearest.map { ($0.0.stablePlaceKey, $0.0.name) }
    }

    private static func resolvedStays(
        places: [PlaceStay],
        frequentPlaces: [FrequentPlace],
        nearbyNames: [String: String],
        dayStart: Date,
        shift: Int
    ) -> [Stay] {
        var result: [Stay] = []
        for place in places.sorted(by: { $0.span.start < $1.span.start }) {
            let start = minute(place.span.start, dayStart: dayStart) + shift
            let end = minute(place.span.end, dayStart: dayStart) + shift
            guard start < end else { continue }
            var stay: Stay
            if let registered = registeredName(for: place, frequentPlaces: frequentPlaces) {
                stay = Stay(
                    key: registered.key, title: registered.name, isRegistered: true,
                    id: "\(place.id)", start: start, end: end
                )
            } else {
                let nearby = place.point.flatMap { nearbyNames[nameKey(for: $0)] }
                stay = Stay(
                    key: nearby ?? place.placeKey, title: nearby ?? place.displayName, isRegistered: false,
                    id: "\(place.id)", start: start, end: end
                )
            }
            // 겹치면 나중에 시작한 곳이 이어받는다.
            if let last = result.last, last.end > start {
                result[result.count - 1].end = start
                if start <= last.start { result.removeLast() }
            }
            stay.start = start
            result.append(stay)
        }
        return result
    }

    private static func joinSamePlace(_ stays: [Stay], moves: [Range<Int>]) -> [Stay] {
        var result: [Stay] = []
        for stay in stays.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.key == stay.key,
               stay.start - last.end <= sameplaceJoinMinutes,
               !moves.contains(where: { $0.lowerBound >= last.end && $0.upperBound <= stay.start && !$0.isEmpty }) {
                result[result.count - 1].end = stay.end
            } else {
                result.append(stay)
            }
        }
        return result
    }

    private static func timeline(stays: [Stay], moves: [Range<Int>]) -> [NLEPlaceSegment] {
        var result = stays.map {
            NLEPlaceSegment(
                id: $0.id, title: $0.title, startMinute: $0.start, endMinute: $0.end,
                kind: $0.isRegistered ? .registered : .visited
            )
        }
        for move in moves {
            let from = stays.last { $0.end <= move.lowerBound }
            let to = stays.first { $0.start >= move.upperBound }
            result.append(NLEPlaceSegment(
                id: "move-\(move.lowerBound)",
                title: transitTitle(from: from?.title, to: to?.title),
                startMinute: move.lowerBound, endMinute: move.upperBound, kind: .transit
            ))
        }
        // 이동 클립이 없어도 다른 곳으로 옮겨 갔다면 그 사이를 잇는다.
        for (from, to) in zip(stays, stays.dropFirst()) where from.key != to.key {
            let gap = to.start - from.end
            guard gap > 0, gap <= maximumInferredTransitMinutes,
                  !moves.contains(where: { $0.overlaps(from.end..<to.start) }) else { continue }
            result.append(NLEPlaceSegment(
                id: "gap-\(from.end)",
                title: transitTitle(from: from.title, to: to.title),
                startMinute: from.end, endMinute: to.start, kind: .transit
            ))
        }
        return result.sorted { $0.startMinute < $1.startMinute }
    }

    private static func transitTitle(from: String?, to: String?) -> String {
        switch (from, to) {
        case let (from?, to?) where from == to:
            return AppLanguagePreference.text(korean: "\(from) 주변 이동", english: "Around \(from)")
        case let (from?, to?): return "\(from) → \(to)"
        case let (from?, nil): return "\(from) →"
        case let (nil, to?): return "→ \(to)"
        case (nil, nil): return AppLanguagePreference.text(korean: "이동", english: "Moving")
        }
    }

    private static func merged(_ spans: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, span.lowerBound - last.upperBound <= movementJoinMinutes {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
            } else {
                result.append(span)
            }
        }
        return result
    }

    private static func subtract(_ cut: Range<Int>, from span: Range<Int>) -> [Range<Int>] {
        guard cut.overlaps(span) else { return [span] }
        var pieces: [Range<Int>] = []
        if span.lowerBound < cut.lowerBound { pieces.append(span.lowerBound..<cut.lowerBound) }
        if cut.upperBound < span.upperBound { pieces.append(cut.upperBound..<span.upperBound) }
        return pieces
    }

    private static func minute(_ date: Date, dayStart: Date) -> Int {
        min(max(Int((date.timeIntervalSince(dayStart) / 60).rounded()), 0), NLETrack.dayMinutes)
    }
}

/// 클립 편집기의 장소 줄과 재생 헤드 핸들.
extension MapHomeNLEClipEditor {
    /// 메인 줄의 이동 클립. 장소 줄의 이동 칸이 이 경계에 맞춘다.
    var movementSpans: [Range<Int>] {
        track.clips
            .filter { $0.option.categoryID == "movement" && $0.startMinute < $0.endMinute }
            .map { $0.startMinute..<$0.endMinute }
    }

    func rebuildPlaceSegments() {
        let calendar = Calendar.autoupdatingCurrent
        let base = calendar.startOfDay(for: date)
        let frequentPlaces = model.settings.frequentPlaces
        let next = placeDays.keys.sorted().flatMap { offset -> [NLEPlaceSegment] in
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: base) else { return [] }
            return NLEPlaceLane.segments(
                places: placeDays[offset] ?? [],
                frequentPlaces: frequentPlaces,
                movement: movementSpans,
                nearbyNames: nearbyPlaceNames,
                dayStart: dayStart,
                dayOffset: offset
            )
        }
        if placeSegments != next { placeSegments = next }
    }

    func resolveNearbyPlaceNames() async {
        let points = NLEPlaceLane.pointsNeedingNames(
            places: placeDays.values.flatMap { $0 },
            frequentPlaces: model.settings.frequentPlaces
        )
        guard !points.isEmpty else { return }
        let names = await NLENearbyPlaceNames.names(for: points)
        guard !names.isEmpty, names != nearbyPlaceNames else { return }
        nearbyPlaceNames.merge(names) { _, new in new }
        rebuildPlaceSegments()
    }

    func placeColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(placeSegments.filter {
                Double($0.endMinute) >= geometry.visibleStartMinute
                    && Double($0.startMinute) <= geometry.visibleEndMinute
            }) { segment in
                let height = max(3, geometry.height(minutes: Double(segment.endMinute - segment.startMinute)) - 2)
                placeBlock(segment, height: height)
                    .frame(width: width, height: height)
                    .offset(y: geometry.y(forMinute: Double(segment.startMinute)) + 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
        .allowsHitTesting(false)
    }

    private func placeBlock(_ segment: NLEPlaceSegment, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(segment.kind == .transit ? Color.tpAccent.opacity(0.14) : Color.tpInk.opacity(segment.kind == .registered ? 0.1 : 0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        segment.kind == .transit ? Color.tpAccent.opacity(0.45) : Color.tpLine,
                        style: StrokeStyle(lineWidth: 1, dash: segment.kind == .visited ? [3, 3] : [])
                    )
            }
            .overlay(alignment: .topLeading) {
                if height >= 18 {
                    Text(segment.title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: segment.kind == .visited ? .regular : .semibold))
                        .foregroundStyle(Color.tpInk)
                        .lineLimit(max(1, Int(height / 14)))
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 5)
                        .padding(.top, 3)
                }
            }
    }

    /// 눈금 띠에 붙은 재생 헤드 손잡이. 잡는 판정은 `NLEPlayheadPolicy`가 한다.
    func playheadHandle(geometry: NLETimelineGeometry, minute: Int) -> some View {
        let width = min(42, gutterWidth - 4)
        return Text(Self.minuteLabel(minute))
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, height: 24)
            .background(Color.tpAccent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .offset(x: gutterWidth - width, y: geometry.y(forMinute: Double(minute)) - 12)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(language.text("재생 헤드", "Playhead"))
            .accessibilityValue(Self.minuteLabel(minute))
            .accessibilityIdentifier("nlePlayheadHandle")
    }
}
