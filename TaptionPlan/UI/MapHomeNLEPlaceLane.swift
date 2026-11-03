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
    let id: String
    let title: String
    let startMinute: Int
    let endMinute: Int
}

enum NLEPlaceLane {
    /// 그 날 안으로 자른 머문 기록을 겹치지 않게 세운다. 겹치면 나중에 시작한 곳이 이어받고,
    /// 맞닿은 같은 장소는 한 칸으로 잇는다. `dayOffset`은 편집기의 날 오프셋이다(어제 = −1).
    static func segments(places: [PlaceStay], dayStart: Date, dayOffset: Int = 0) -> [NLEPlaceSegment] {
        let shift = dayOffset * NLETrack.dayMinutes
        var result: [(key: String, segment: NLEPlaceSegment)] = []
        for place in places.sorted(by: { $0.span.start < $1.span.start }) {
            let start = minute(place.span.start, dayStart: dayStart) + shift
            let end = minute(place.span.end, dayStart: dayStart) + shift
            guard start < end else { continue }
            if let last = result.last, last.segment.endMinute > start {
                result[result.count - 1].segment = copy(last.segment, endMinute: start)
                if start <= last.segment.startMinute { result.removeLast() }
            }
            if let last = result.last, last.key == place.placeKey, last.segment.endMinute == start {
                result[result.count - 1].segment = copy(last.segment, endMinute: end)
            } else {
                result.append((
                    place.placeKey,
                    NLEPlaceSegment(id: "\(place.id)", title: place.displayName, startMinute: start, endMinute: end)
                ))
            }
        }
        return result.map(\.segment)
    }

    private static func copy(_ segment: NLEPlaceSegment, endMinute: Int) -> NLEPlaceSegment {
        NLEPlaceSegment(id: segment.id, title: segment.title, startMinute: segment.startMinute, endMinute: endMinute)
    }

    private static func minute(_ date: Date, dayStart: Date) -> Int {
        min(max(Int((date.timeIntervalSince(dayStart) / 60).rounded()), 0), NLETrack.dayMinutes)
    }
}

/// 클립 편집기의 장소 줄과 재생 헤드 핸들.
extension MapHomeNLEClipEditor {
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
            .fill(Color.tpInk.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.tpLine, lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if height >= 18 {
                    Text(segment.title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
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
