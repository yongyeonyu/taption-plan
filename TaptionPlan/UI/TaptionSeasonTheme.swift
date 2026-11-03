import Foundation
import os
import SwiftUI

/// 「계절」 지도의 색상표(SEA1103A01). 보고 있는 날짜의 계절 색을 쓰고, 계절의 끝 달에는
/// 다음 계절 색으로 하루씩 넘어간다. 탁해지지 않게 OKLCH에서 섞는다.
enum TaptionSeason: Int, CaseIterable, Sendable {
    case spring, summer, autumn, winter

    struct Colors: Equatable, Sendable {
        /// 배경·면·선·강조·보조 글자·글자.
        var ui: [String]
        var map: Map
        /// 테두리·코랄·꿀·벽돌·민트·장미·하늘·크림·코코아·요일.
        var bar: [String]
    }

    struct Map: Equatable, Sendable {
        var background, land, cover, park, water, waterway: String
        var building, buildingOutline, road, casing: String
        var label, roadLabel, halo, waterLabel, waterHalo, parkLabel, parkHalo, marker, poi: String

        fileprivate var all: [String] {
            [background, land, cover, park, water, waterway, building, buildingOutline, road, casing,
             label, roadLabel, halo, waterLabel, waterHalo, parkLabel, parkHalo, marker, poi]
        }

        fileprivate init(_ v: [String]) {
            background = v[0]; land = v[1]; cover = v[2]; park = v[3]; water = v[4]; waterway = v[5]
            building = v[6]; buildingOutline = v[7]; road = v[8]; casing = v[9]
            label = v[10]; roadLabel = v[11]; halo = v[12]; waterLabel = v[13]; waterHalo = v[14]
            parkLabel = v[15]; parkHalo = v[16]; marker = v[17]; poi = v[18]
        }
    }

    var colors: Colors {
        switch self {
        case .spring:
            Colors(
                ui: ["#FFF7E6", "#FFFCF3", "#F6D6DE", "#B83D6E", "#75584C", "#44302A"],
                map: Map(["#FFFBEA", "#FFF2C4", "#F6EFB2", "#E6EDA0", "#BDE4F2", "#A5D5EA", "#FBD3E0", "#EFB2C6", "#F49FBE", "#FFFFFF",
                          "#5E3F35", "#7A5A4E", "#FFFBEA", "#3F7FA6", "#DDF0FA", "#6B7F2E", "#E6EDA0", "#F49FBE", "#E8739A"]),
                bar: ["#6B4233", "#F7A1BC", "#FFD866", "#E8739A", "#BFE08C", "#F58FB2", "#A9D9EF", "#FFF3B8", "#A8744C", "#C9A98F"]
            )
        case .summer:
            Colors(
                ui: ["#EDF9F3", "#F8FDFB", "#BDE5D5", "#177A62", "#3F665A", "#1B3A32"],
                map: Map(["#F2FBF4", "#DBF2D3", "#C4EAB9", "#9FDB94", "#7CC8EE", "#6AB9E2", "#D3EBF6", "#A0CDE2", "#5EB0DA", "#FFFFFF",
                          "#1F4A3C", "#2F5E50", "#F2FBF4", "#1F6E99", "#D6F0FC", "#2E6F3C", "#9FDB94", "#5EB0DA", "#2F9E7F"]),
                bar: ["#1E4F40", "#66C8A0", "#6CC4EC", "#2F9E7F", "#A5E08F", "#4FB8C4", "#6CC4EC", "#D6F3FF", "#3F8A73", "#8DB8A8"]
            )
        case .autumn:
            Colors(
                ui: ["#FBF0E0", "#FFF9EF", "#E9CCA6", "#B0451A", "#73523A", "#3F2818"],
                map: Map(["#FBF3E3", "#F4E1BE", "#ECCE98", "#E6A25C", "#B4D2DA", "#9CC2CC", "#E8C6A0", "#C89C6E", "#C95D2A", "#FFF6E6",
                          "#4E2F1B", "#6B4630", "#FBF3E3", "#3F6F80", "#DCEBEF", "#8A4A1C", "#E6A25C", "#C95D2A", "#B5401E"]),
                bar: ["#5A3219", "#E26A2C", "#F2B441", "#B5401E", "#C9A24A", "#D9572A", "#9CC2CC", "#FBE3B8", "#A8763E", "#C2A07C"]
            )
        case .winter:
            Colors(
                ui: ["#F6F7F9", "#FFFFFF", "#DDE1E6", "#5B6470", "#646D77", "#2A2E34"],
                map: Map(["#FCFCFD", "#F1F3F5", "#E8EBEE", "#DDE1E5", "#D3DCE4", "#BEC9D3", "#FFFFFF", "#C9CED4", "#9AA2AB", "#FFFFFF",
                          "#3A3F46", "#5B6470", "#FCFCFD", "#566A7A", "#E8EEF3", "#555E66", "#DDE1E5", "#9AA2AB", "#6B7480"]),
                bar: ["#4A515A", "#9AA2AB", "#FFFFFF", "#5B6470", "#C3CAD1", "#7E8791", "#D3DCE4", "#F2F4F7", "#6B7480", "#AEB5BD"]
            )
        }
    }

    /// 3·4·5월 봄, 6·7·8월 여름, 9·10·11월 가을, 12·1·2월 겨울.
    /// 끝 달(5·8·11·2월)에만 다음 계절로 넘어가며 다음 달 1일에 100%가 된다.
    static func position(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> (season: TaptionSeason, progress: Double) {
        let month = calendar.component(.month, from: date)
        let season: TaptionSeason = switch month {
        case 3, 4, 5: .spring
        case 6, 7, 8: .summer
        case 9, 10, 11: .autumn
        default: .winter
        }
        guard [5, 8, 11, 2].contains(month),
              let days = calendar.range(of: .day, in: .month, for: date)?.count else { return (season, 0) }
        return (season, Double(calendar.component(.day, from: date) - 1) / Double(days))
    }

    var next: TaptionSeason { TaptionSeason(rawValue: (rawValue + 1) % 4) ?? .spring }

    static func colors(on date: Date, calendar: Calendar = .autoupdatingCurrent) -> Colors {
        let (season, progress) = position(on: date, calendar: calendar)
        let from = season.colors
        guard progress > 0 else { return from }
        let to = season.next.colors
        func mix(_ a: [String], _ b: [String]) -> [String] {
            zip(a, b).map { OKLCH.mix($0, $1, progress) }
        }
        return Colors(ui: mix(from.ui, to.ui), map: Map(mix(from.map.all, to.map.all)), bar: mix(from.bar, to.bar))
    }
}

/// 지금 보고 있는 날짜의 계절 색. 색을 읽을 때마다 계산하지 않도록 만들어 둔다.
enum TaptionSeasonStore {
    struct State: Sendable {
        var key: String
        var colors: TaptionSeason.Colors
        var palette: TaptionUITheme.Palette
        var bar: TaptionBarPalette
    }

    private static let state = OSAllocatedUnfairLock<State>(initialState: make(on: .now))

    private static func make(on date: Date) -> State {
        let colors = TaptionSeason.colors(on: date)
        let (season, progress) = TaptionSeason.position(on: date)
        return State(
            key: "\(season.rawValue)-\(Int((progress * 1_000).rounded()))",
            colors: colors,
            palette: TaptionUITheme.palette(colors.ui),
            bar: TaptionBarPalette(colors.bar)
        )
    }

    static var current: State { state.withLock { $0 } }

    /// 색이 실제로 바뀔 때만 교체한다. 같은 계절 안에서 날짜를 넘겨도 다시 칠하지 않는다.
    static func select(_ date: Date) {
        let next = make(on: date)
        state.withLock { if $0.key != next.key { $0 = next } }
    }
}

enum OKLCH {
    private static func channels(_ hex: String) -> [Double] {
        let digits = hex.dropFirst()
        return stride(from: 0, to: 6, by: 2).map { offset in
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let value = Double(Int(digits[start..<digits.index(start, offsetBy: 2)], radix: 16) ?? 0) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
    }

    private static func lch(_ hex: String) -> (l: Double, c: Double, h: Double) {
        let v = channels(hex)
        let l = cbrt(0.4122214708 * v[0] + 0.5363325363 * v[1] + 0.0514459929 * v[2])
        let m = cbrt(0.2119034982 * v[0] + 0.6806995451 * v[1] + 0.1073969566 * v[2])
        let s = cbrt(0.0883024619 * v[0] + 0.2817188376 * v[1] + 0.6299787005 * v[2])
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, hypot(a, b), atan2(b, a))
    }

    private static func encode(_ value: Double) -> Int {
        let v = min(1, max(0, value))
        return Int(((v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055) * 255).rounded())
    }

    static func mix(_ first: String, _ second: String, _ t: Double) -> String {
        guard t > 0 else { return first }
        guard t < 1 else { return second }
        let a = lch(first), b = lch(second)
        // 무채색은 색상각이 의미 없어 상대 쪽 색상각을 그대로 쓴다.
        var delta = (b.h - a.h + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if delta < 0 { delta += 2 * .pi }
        delta -= .pi
        let hue = a.c < 0.02 ? b.h : b.c < 0.02 ? a.h : a.h + delta * t
        let chroma = a.c + (b.c - a.c) * t, lightness = a.l + (b.l - a.l) * t
        let x = chroma * cos(hue), y = chroma * sin(hue)
        let l = pow(lightness + 0.3963377774 * x + 0.2158037573 * y, 3)
        let m = pow(lightness - 0.1055613458 * x - 0.0638541728 * y, 3)
        let s = pow(lightness - 0.0894841775 * x - 1.2914855480 * y, 3)
        return String(
            format: "#%02X%02X%02X",
            encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }
}
