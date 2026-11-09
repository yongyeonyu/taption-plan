#if DEBUG
import CoreLocation
import SwiftUI

/// `-inkPreview`로 여는 수묵 테마 확인 화면(INK1108A01, Debug 전용). 견본 머묾으로 도장 핀과 장소 도감을 그린다.
/// 실제 기록은 읽지도 쓰지도 않는다.
struct MapHomeInkPreviewHost: View {
    private let places: [FrequentPlace]
    private let stays: [PlaceStay]

    init() {
        TaptionUITheme.apply(.ink)
        func point(_ lat: Double, _ lon: Double) -> GeoPoint {
            GeoPoint(latitude: lat, longitude: lon, altitude: 0, horizontalAccuracy: 5, verticalAccuracy: -1)
        }
        let places = [
            FrequentPlace(kind: .home, point: point(37.5665, 126.9780)),
            FrequentPlace(kind: .company, point: point(37.5700, 126.9820)),
            FrequentPlace(kind: .school, point: point(37.5600, 126.9400)),
            FrequentPlace(kind: .restaurant, name: "국숫집", point: point(37.5710, 126.9790)),
            FrequentPlace(kind: .custom, name: "서점", point: point(37.5750, 126.9850)),
        ]
        let now = Date.now
        func stay(_ key: String, hoursAgo: Double, at point: GeoPoint? = nil) -> PlaceStay {
            let start = now.addingTimeInterval(-hoursAgo * 3_600)
            return PlaceStay(placeKey: key, displayName: key, span: TimeSpan(start: start, end: start.addingTimeInterval(1_800)),
                confidence: .high, point: point)
        }
        self.places = places
        self.stays = [
            stay(places[0].stablePlaceKey, hoursAgo: 1),
            stay(places[1].stablePlaceKey, hoursAgo: 0.6),
            stay(places[3].stablePlaceKey, hoursAgo: 0.2),
            stay("place-namsan", hoursAgo: 30, at: point(37.5512, 126.9882)),
            stay("place-gyeongbok", hoursAgo: 50, at: point(37.5796, 126.9770)),
        ]
    }

    var body: some View {
        let today = Calendar.autoupdatingCurrent.startOfDay(for: .now)
        let keys = MapHomePlaceStampPolicy.stampedKeys(stays: stays, dayStart: today, dayEnd: today.addingTimeInterval(86_400))
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(places.filter { $0.kind != .home }, id: \.id) { place in
                    MapHomePlacePin(
                        name: place.displayName, floor: nil,
                        destination: MapHomeLocationDestination(placeKind: place.kind) ?? .user,
                        stamp: MapHomePlaceStampPolicy.mark(for: place, stampedKeys: keys)
                    )
                    .fixedSize()
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color(hex: MapHomeInkWash.Map.paper))
            MapHomePlaceBookSheet(stays: stays, language: .korean)
        }
        .preferredColorScheme(.light)
    }
}
#endif
