import SwiftUI
import TaptionPlanCore

/// 등록 장소 도장 한 개(INK1108A01). 머문 기록에서 매번 다시 구하는 표시 값이라 저장하지 않는다.
struct MapHomePlaceStampMark: Equatable, Sendable {
    let glyph: String
    let isStamped: Bool
}

/// 도장 판정. 원본 머묾(`PlaceStay`)은 읽기만 한다.
///
/// 등록 장소 판정(`FrequentPlaceResolutionEngine`)이 머묾에 붙인 키가 그 장소의 `stablePlaceKey`이면 도착한 것이다.
/// 최소 체류 시간은 그 판정이 이미 걸렀으므로 여기서 다시 따지지 않는다.
enum MapHomePlaceStampPolicy {
    /// 종류에서 한 글자. 집 家·회사 社·학교 學·식당 食, 나머지는 이름 첫 글자.
    static func glyph(kind: FrequentPlaceKind, name: String) -> String {
        switch kind {
        case .home: "家"
        case .company: "社"
        case .school: "學"
        case .restaurant: "食"
        case .academy, .hobby, .exercise, .custom:
            name.trimmingCharacters(in: .whitespacesAndNewlines).first.map(String.init) ?? "印"
        }
    }

    /// `day`부터 하루 안에 머문 등록 장소 키. 지금 머무는 중인 곳도 들어간다.
    static func stampedKeys(stays: [PlaceStay], dayStart: Date, dayEnd: Date) -> Set<String> {
        Set(stays.lazy.filter { $0.span.start < dayEnd && dayStart < $0.span.end }.map(\.placeKey))
    }

    /// 장소마다 처음 도착한 시각. 도감이 "처음 찍은 날"로 쓴다.
    static func firstArrivals(stays: [PlaceStay], keys: Set<String>) -> [String: Date] {
        var first: [String: Date] = [:]
        for stay in stays where keys.contains(stay.placeKey) {
            if let known = first[stay.placeKey], known <= stay.span.start { continue }
            first[stay.placeKey] = stay.span.start
        }
        return first
    }

    static func mark(for place: FrequentPlace, stampedKeys: Set<String>) -> MapHomePlaceStampMark {
        MapHomePlaceStampMark(
            glyph: glyph(kind: place.kind, name: place.displayName),
            isStamped: stampedKeys.contains(place.stablePlaceKey)
        )
    }
}

/// 지도 핀의 도장 캐시 키. 날짜와 머묾 수·마지막 머묾 끝이 같으면 다시 훑지 않는다.
struct MapHomePlaceStampKey: Equatable {
    let dayStart: Date
    let stayCount: Int
    let lastStayEnd: Date?
    let placeKeys: [String]
}

/// 붉은 네모 도장. 찍은 곳은 인주로 채우고 살짝 기울이며, 아직이면 먹 점선 테두리만 그린다.
struct MapHomePlaceSeal: View {
    let mark: MapHomePlaceStampMark
    var size: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
        ZStack {
            if mark.isStamped {
                shape.fill(Color(hex: MapHomeInkWash.sealHex).opacity(0.92))
                shape.inset(by: size * 0.08)
                    .stroke(Color(hex: "#F8F2E4").opacity(0.85), lineWidth: max(1, size * 0.045))
            } else {
                shape.fill(Color(hex: "#F8F2E4").opacity(0.7))
                shape.stroke(
                    Color(hex: MapHomeInkWash.Map.ink).opacity(0.55),
                    style: StrokeStyle(lineWidth: max(1, size * 0.05), dash: [size * 0.12, size * 0.09])
                )
            }
            Text(mark.glyph)
                .font(.system(size: size * 0.56, weight: .heavy, design: .serif))
                .foregroundStyle(mark.isStamped ? Color(hex: "#F8F2E4") : Color(hex: MapHomeInkWash.Map.ink).opacity(0.45))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(mark.isStamped ? -8 : 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mark.isStamped
            ? AppLanguagePreference.runtimeText("도장 찍음", "Stamped")
            : AppLanguagePreference.runtimeText("아직 도장 없음", "Not stamped yet"))
    }
}

extension MapHomeView {
    /// 수묵 테마일 때만 보고 있는 날의 도장 키를 구한다. 다른 테마는 nil이라 핀에 도장이 없다.
    var placeStampedKeys: Set<String>? {
        guard TaptionUITheme.current == .ink else { return nil }
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: model.selectedDate)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let stays = model.snapshot.places
        let key = MapHomePlaceStampKey(
            dayStart: start, stayCount: stays.count, lastStayEnd: stays.last?.span.end,
            placeKeys: model.settings.frequentPlaces.map(\.stablePlaceKey)
        )
        return placeStampMemo.value(for: key) {
            MapHomePlaceStampPolicy.stampedKeys(stays: stays, dayStart: start, dayEnd: end)
        }
    }
}
