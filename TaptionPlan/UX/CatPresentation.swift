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

    /// 고를 수 있는 캐릭터 셋(CHR1103A01). 옛 설정의 다른 털색은 그대로 읽는다.
    static let characters: [CatCoat] = [.white, .calico, .mackerel]

    var displayName: String {
        switch self {
        case .white: "화랑이"
        case .calico: "춘향이"
        case .mackerel: "윤복이"
        default: rawValue
        }
    }

    /// 이름은 번역하지 않고 한국어가 아니면 영어로 쓴다.
    var englishName: String {
        switch self {
        case .white: "Hwarang"
        case .calico: "Chunhyang"
        case .mackerel: "Yunbok"
        default: String(describing: self).capitalized
        }
    }

    var shortName: String {
        rawValue.replacingOccurrences(of: " 고양이", with: "")
    }

    var caption: String {
        switch self {
        case .white: "수컷 · 흰 털 · 파란 눈"
        case .calico: "암컷 · 삼색 털 · 호박색 눈"
        case .mackerel: "암컷 · 줄무늬 · 흰 가슴과 양말"
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
