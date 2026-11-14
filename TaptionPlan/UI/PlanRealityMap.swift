import MapKit
import SwiftUI
import TaptionPlanCore
import TaptionPlanStore

/// 지도에 그릴 계획·실제 경로(PVR1114A13).
enum PlanRealityRoute {
    /// 실제 이동 경로: 정확도 200m 안의 정밀 위치를 시각 순으로 잇고, 그리기 전에 줄인다.
    static func actual(_ readings: [SensorReading], in day: TimeSpan) -> [CLLocationCoordinate2D] {
        let points = readings
            .filter { $0.locationFixQuality != .approximate && day.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap(\.point)
            .filter { $0.horizontalAccuracy <= 200 }
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        return RoutePolylineDecimator.decimate(points)
    }

    /// 계획 경로: 그날 여행 일정의 곳을 순서대로 이은 선.
    static func planned(_ stops: [TravelPlanStop]) -> [[CLLocationCoordinate2D]] {
        TravelGreatCircleAdapter.paths(stops.map(\.coordinate))
    }
}

/// 계획 경로는 점선, 실제 이동 경로는 실선. 토글 하나로 실제 경로를 겹친다.
struct PlanRealityMap: View {
    let stops: [TravelPlanStop]
    let actual: [CLLocationCoordinate2D]
    let language: MapHomeLanguage
    @Binding var showsActual: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(language.text("실제 경로 겹쳐 보기", "Overlay actual route"), isOn: $showsActual)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.body), weight: .semibold))
                .tint(TravelInk.actual)
            Map(initialPosition: position) {
                ForEach(Array(PlanRealityRoute.planned(stops).enumerated()), id: \.offset) { _, path in
                    MapPolyline(coordinates: path)
                        .stroke(TravelInk.plan.opacity(0.75), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [2, 7]))
                }
                if showsActual, actual.count >= 2 {
                    MapPolyline(coordinates: actual)
                        .stroke(TravelInk.actual, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
                }
                ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                    Marker(stop.title, monogram: Text(verbatim: "\(index + 1)"), coordinate: stop.coordinate)
                        .tint(TravelInk.plan)
                }
            }
            .frame(height: 240)
            .clipShape(RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
            // 그날의 내용이 바뀌면 카메라를 다시 맞춘다.
            .id(MapKey(stops: stops.map(\.id), actual: actual.count, showsActual: showsActual))
            if stops.count < 2 {
                Text(language.text("이 날은 계획 경로가 없어 실제 경로만 보입니다.", "No planned route for this day, so only the actual route is shown."))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.caption)))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
    }

    private struct MapKey: Hashable {
        var stops: [UUID]
        var actual: Int
        var showsActual: Bool
    }

    /// 한 곳뿐이고 실제 경로도 없으면 자동 맞춤이 최대로 확대해 빈 지도가 된다.
    private var position: MapCameraPosition {
        guard stops.count == 1, let stop = stops.first, !(showsActual && actual.count >= 2) else { return .automatic }
        return .region(MKCoordinateRegion(center: stop.coordinate, latitudinalMeters: 20_000, longitudinalMeters: 20_000))
    }
}
