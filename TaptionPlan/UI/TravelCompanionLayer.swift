@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// 여행 지도 위의 동행 표시와 모이는 곳 핀(LOC1116S01). `TravelStreetMap`은 이 층에 맡기기만 한다.
@MainActor
final class TravelCompanionLayer {
    final class Pin: MLNPointAnnotation {
        var mark: TravelCompanionMark?
    }

    private var shown: [TravelCompanionMark] = []
    private var pins: [Pin] = []

    func sync(_ mapView: MLNMapView, marks: [TravelCompanionMark]) {
        guard marks != shown else { return }
        shown = marks
        mapView.removeAnnotations(pins)
        pins = marks.map { mark in
            let pin = Pin()
            pin.coordinate = CLLocationCoordinate2D(latitude: mark.latitude, longitude: mark.longitude)
            pin.mark = mark
            return pin
        }
        mapView.addAnnotations(pins)
    }

    func view(for annotation: MLNAnnotation) -> MLNAnnotationView? {
        guard let pin = annotation as? Pin, let mark = pin.mark else { return nil }
        let side: CGFloat = 30
        let view = MLNAnnotationView(annotation: annotation, reuseIdentifier: nil)
        view.frame = CGRect(x: 0, y: 0, width: side, height: side)
        let color = UIColor(Color(hex: mark.colorHex))
        let disc = UIView(frame: view.bounds)
        disc.backgroundColor = color
        disc.layer.cornerRadius = side / 2
        disc.layer.borderWidth = mark.isHelp ? 3 : 2
        disc.layer.borderColor = (mark.isHelp ? UIColor.systemRed : UIColor.white).cgColor
        disc.alpha = mark.opacity
        view.addSubview(disc)
        if mark.kind == .meet {
            let icon = UIImageView(image: UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)))
            icon.tintColor = .white
            icon.frame = view.bounds
            icon.contentMode = .center
            disc.addSubview(icon)
            view.layer.zPosition = 5
        } else {
            let label = UILabel(frame: view.bounds)
            label.text = mark.initial
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 14, weight: .semibold)
            label.textColor = .white
            disc.addSubview(label)
            view.layer.zPosition = mark.isHelp ? 9 : 6
        }
        if !mark.caption.isEmpty {
            let caption = UILabel()
            caption.text = mark.caption
            caption.font = .systemFont(ofSize: 10, weight: .medium)
            caption.textColor = mark.isHelp ? .systemRed : UIColor(TravelInk.plan)
            caption.backgroundColor = UIColor.white.withAlphaComponent(0.88)
            caption.textAlignment = .center
            caption.layer.cornerRadius = 4
            caption.layer.masksToBounds = true
            let width = min(120, caption.intrinsicContentSize.width + 8)
            caption.frame = CGRect(x: side / 2 - width / 2, y: side + 2, width: width, height: 15)
            view.addSubview(caption)
        }
        view.accessibilityLabel = (mark.kind == .meet ? "" : mark.initial + " ") + mark.caption
        return view
    }
}
