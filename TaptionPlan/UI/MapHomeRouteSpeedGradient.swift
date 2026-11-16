import CoreLocation
import Foundation
import SwiftUI

// MARK: - Route speed gradient

/// 실제 경로를 속도 구간별 색(느림 빨강 → 중간 초록 → 빠름 파랑, `MapHomePawprintSpeedColor` 척도)으로 나눈다.
enum MapHomeRouteSpeedGradient {
    /// 구간 하나가 묶는 간선 수. 경로가 늘어나도 구간 경계가 움직이지 않아 이미 그린 색이 바뀌지 않는다.
    static let edgesPerPiece = 4
    static let maximumPieces = 1_000

    struct Piece: Equatable {
        /// 경로 좌표 인덱스 범위(양 끝 포함). 인접 구간은 끝점을 공유한다.
        let startIndex: Int
        let endIndex: Int
        let speedMetersPerSecond: Double
        let colorHex: String
    }

    /// 속도를 알 수 없으면(시각 없음·모두 같은 시각 등) nil을 돌려 단색으로 되돌린다.
    static func pieces(
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date],
        maximumPieces: Int = maximumPieces
    ) -> [Piece]? {
        guard coordinates.count >= 2,
              coordinates.count == timestamps.count,
              maximumPieces > 0 else { return nil }
        let edgeCount = coordinates.count - 1
        // 구간 경계는 절대 인덱스(stride의 배수)로 고정한다. 아주 긴 경로에서만 stride를 두 배로 늘린다.
        var stride = edgesPerPiece
        while (edgeCount + stride - 1) / stride > maximumPieces { stride *= 2 }
        let pieceCount = (edgeCount + stride - 1) / stride
        var rawSpeeds: [Double?] = []
        rawSpeeds.reserveCapacity(pieceCount)
        var bounds: [(start: Int, end: Int)] = []
        bounds.reserveCapacity(pieceCount)
        for piece in 0..<pieceCount {
            let start = piece * stride
            let end = min(edgeCount, (piece + 1) * stride)
            bounds.append((start, end))
            var meters = 0.0
            var seconds = 0.0
            for edge in start..<end {
                let duration = timestamps[edge + 1].timeIntervalSince(timestamps[edge])
                guard duration > 0, duration.isFinite else { continue }
                let distance = CLLocation(
                    latitude: coordinates[edge].latitude,
                    longitude: coordinates[edge].longitude
                ).distance(from: CLLocation(
                    latitude: coordinates[edge + 1].latitude,
                    longitude: coordinates[edge + 1].longitude
                ))
                guard distance.isFinite else { continue }
                meters += distance
                seconds += duration
            }
            rawSpeeds.append(seconds > 0 ? meters / seconds : nil)
        }
        guard let filled = fillGaps(rawSpeeds) else { return nil }
        let smoothed = movingAverage(filled)
        return zip(bounds, smoothed).map { bound, speed in
            Piece(
                startIndex: bound.start,
                endIndex: bound.end,
                speedMetersPerSecond: speed,
                colorHex: colorHex(forMetersPerSecond: speed)
            )
        }
    }

    /// 이웃 구간의 속도로 빈 구간을 메운다. 전부 비어 있으면 nil.
    static func fillGaps(_ speeds: [Double?]) -> [Double]? {
        guard speeds.contains(where: { $0 != nil }) else { return nil }
        var result: [Double?] = speeds
        var last: Double?
        for index in result.indices {
            if let value = result[index] { last = value } else { result[index] = last }
        }
        var next: Double?
        for index in result.indices.reversed() {
            if let value = result[index] { next = value } else { result[index] = next }
        }
        return result.compactMap { $0 }
    }

    /// 3점 이동 평균으로 인접 구간 색이 급변하지 않게 한다.
    static func movingAverage(_ speeds: [Double]) -> [Double] {
        speeds.indices.map { index in
            let lower = max(0, index - 1)
            let upper = min(speeds.count - 1, index + 1)
            let window = speeds[lower...upper]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    static func colorHex(forMetersPerSecond speed: Double) -> String {
        let ratio = MapHomePawprintSpeedColor.ratio(forMetersPerSecond: speed) ?? 0
        let rgb = rgb(hue: (2.0 / 3.0) * ratio, saturation: 0.85, brightness: 0.82)
        return String(
            format: "#%02X%02X%02X",
            Int((rgb.red * 255).rounded()),
            Int((rgb.green * 255).rounded()),
            Int((rgb.blue * 255).rounded())
        )
    }

    private static func rgb(
        hue: Double,
        saturation: Double,
        brightness: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let scaled = (hue - hue.rounded(.down)) * 6
        let sector = Int(scaled) % 6
        let fraction = scaled - Double(Int(scaled))
        let p = brightness * (1 - saturation)
        let q = brightness * (1 - saturation * fraction)
        let t = brightness * (1 - saturation * (1 - fraction))
        switch sector {
        case 0: return (brightness, t, p)
        case 1: return (q, brightness, p)
        case 2: return (p, brightness, t)
        case 3: return (p, q, brightness)
        case 4: return (t, p, brightness)
        default: return (brightness, p, q)
        }
    }
}

/// 그라데이션 구간 하나를 지도 렌더러가 그릴 선으로 옮긴 값.
struct MapHomeRouteGradientSlice {
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let geometrySignature: Int
    let colorHex: String
}

enum MapHomeRouteGradientSlicer {
    static func slices(
        overlayID: String,
        coordinates: [CLLocationCoordinate2D],
        timestamps: [Date]
    ) -> [MapHomeRouteGradientSlice]? {
        guard let pieces = MapHomeRouteSpeedGradient.pieces(
            coordinates: coordinates,
            timestamps: timestamps
        ) else { return nil }
        return pieces.enumerated().map { index, piece in
            let slice = Array(coordinates[piece.startIndex...piece.endIndex])
            return MapHomeRouteGradientSlice(
                id: "\(overlayID)#g\(index)",
                coordinates: slice,
                geometrySignature: MapHomeRouteGeometrySignature.value(for: slice),
                colorHex: piece.colorHex
            )
        }
    }
}
