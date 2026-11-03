import Foundation
import SwiftUI

enum CatCoat: String, CaseIterable, Identifiable {
    case white = "흰색 고양이"
    case calico = "삼색 고양이"
    case mackerel = "고등어 고양이"
    case black = "검정 고양이"
    case gray = "회색 고양이"
    case cheese = "치즈 고양이"
    case cow = "젖소무늬 고양이"

    var id: Self { self }

    var shortName: String {
        rawValue.replacingOccurrences(of: " 고양이", with: "")
    }

    var caption: String {
        switch self {
        case .white: "깨끗한 흰 털"
        case .calico: "흰색 · 검정 · 주황"
        case .mackerel: "회갈색 줄무늬"
        case .black: "노란 눈 · 검은 털"
        case .gray: "차분한 회색 털"
        case .cheese: "주황색 줄무늬"
        case .cow: "흰색 · 검정 얼룩"
        }
    }

}

struct CatMotionPolicy: Equatable, Sendable {
    var style: CatStyle
    var isRunning: Bool
    var animationDuration: TimeInterval

    static func resolve(
        style: CatStyle,
        hasCurrentActivity: Bool,
        reduceMotion: Bool
    ) -> CatMotionPolicy {
        CatMotionPolicy(
            style: style,
            isRunning: hasCurrentActivity && !reduceMotion,
            animationDuration: hasCurrentActivity && !reduceMotion ? 2 : 0
        )
    }
}
