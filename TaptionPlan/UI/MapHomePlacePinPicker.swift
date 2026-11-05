@preconcurrency import MapLibre
import SwiftUI
import TaptionPlanCore

/// 등록 지점 위치 고르기(PIN1105A01). 핀은 화면 가운데에 있고 지도를 움직여 맞춘다. 저장 단추를 눌러야 저장한다.
struct MapHomePlacePinPicker: View {
    let point: GeoPoint?
    let fallback: GeoPoint?
    let tint: Color
    let language: MapHomeLanguage
    /// nil이면 부모가 높이를 정한다.
    var height: CGFloat? = 340
    let onSave: (CLLocationCoordinate2D) -> Void

    @State private var center: CLLocationCoordinate2D
    @State private var zoom: Double
    @State private var recenterToken = 0

    init(
        point: GeoPoint?,
        fallback: GeoPoint?,
        tint: Color,
        language: MapHomeLanguage,
        height: CGFloat? = 340,
        onSave: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        self.point = point
        self.fallback = fallback
        self.tint = tint
        self.language = language
        self.height = height
        self.onSave = onSave
        let start = point ?? fallback
        _center = State(initialValue: CLLocationCoordinate2D(
            latitude: start?.latitude ?? 37.5665,
            longitude: start?.longitude ?? 126.9780
        ))
        _zoom = State(initialValue: start == nil ? 11 : 16)
    }

    private var canSave: Bool {
        MapHomePlacePinPolicy.needsSave(saved: point, center: center)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                MapHomePlacePinMap(center: $center, zoom: $zoom, recenterToken: recenterToken)
                // 핀 끝이 지도 가운데를 가리키게 올린다.
                MapHomePlacementPin()
                    .offset(y: -MapHomePlacementPin.height / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                zoomButtons
            }
            .frame(minHeight: 200)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            Button {
                onSave(center)
            } label: {
                Text(canSave
                    ? language.text("이 위치로 저장", "Save this location")
                    : language.text("지도를 움직여 핀을 맞추세요", "Move the map to place the pin"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(canSave ? Color.white : Color.tpSecondary)
                    .background(canSave ? tint : Color.tpBackground, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .accessibilityIdentifier("placePinSave")
        }
        // 검색이나 현재 위치로 저장되면 그 자리로 옮긴다.
        .onChange(of: point) { _, value in
            guard let value else { return }
            center = CLLocationCoordinate2D(latitude: value.latitude, longitude: value.longitude)
            recenterToken += 1
        }
    }

    private var zoomButtons: some View {
        VStack(spacing: 0) {
            zoomButton("plus", label: language.text("확대", "Zoom in"), delta: 1)
            Divider()
            zoomButton("minus", label: language.text("축소", "Zoom out"), delta: -1)
        }
        .frame(width: 44)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(8)
    }

    private func zoomButton(_ symbol: String, label: String, delta: Double) -> some View {
        Button {
            zoom = MapHomePlacePinPolicy.zoom(zoom, by: delta)
            recenterToken += 1
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.tpInk)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

enum MapHomePlacePinPolicy {
    static let zoomRange = 3.0...20.0
    /// 이보다 적게 움직이면 지도 흔들림으로 본다.
    static let minimumMoveMeters = 3.0

    static func zoom(_ current: Double, by delta: Double) -> Double {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, current + delta))
    }

    static func needsSave(saved: GeoPoint?, center: CLLocationCoordinate2D) -> Bool {
        guard let saved else { return true }
        let distance = CLLocation(latitude: saved.latitude, longitude: saved.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        return distance >= minimumMoveMeters
    }
}

private struct MapHomePlacePinMap: UIViewRepresentable {
    @Binding var center: CLLocationCoordinate2D
    @Binding var zoom: Double
    let recenterToken: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleJSON: MapHomeVectorStyle.casual.json)
        mapView.delegate = context.coordinator
        mapView.allowsRotating = false
        mapView.allowsTilting = false
        mapView.showsCompassView = false
        mapView.showsLogoView = false
        // 지도 출처 (i) 버튼은 숨기지 않는다(출처 표기 의무).
        mapView.showsAttributionButton = true
        mapView.minimumZoomLevel = MapHomePlacePinPolicy.zoomRange.lowerBound
        mapView.maximumZoomLevel = MapHomePlacePinPolicy.zoomRange.upperBound
        mapView.setCenter(center, zoomLevel: zoom, animated: false)
        context.coordinator.recenterToken = recenterToken
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.onMove = { center, zoom in
            self.center = center
            self.zoom = zoom
        }
        guard context.coordinator.recenterToken != recenterToken else { return }
        context.coordinator.recenterToken = recenterToken
        mapView.setCenter(center, zoomLevel: zoom, animated: true)
    }

    final class Coordinator: NSObject, @preconcurrency MLNMapViewDelegate {
        var recenterToken = 0
        var onMove: ((CLLocationCoordinate2D, Double) -> Void)?

        // 값은 지도가 멈췄을 때만 올린다. 움직이는 동안 SwiftUI를 다시 그리지 않는다.
        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            onMove?(mapView.centerCoordinate, mapView.zoomLevel)
        }
    }
}
