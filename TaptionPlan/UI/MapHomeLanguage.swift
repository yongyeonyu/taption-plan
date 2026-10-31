import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

enum MapHomeLanguage: String, CaseIterable, Identifiable {
    case korean
    case english

    /// 저장된 앱 언어 설정을 따른다(화면 밖 알림·카드 생성에서도 같은 언어를 쓴다).
    static var current: MapHomeLanguage {
        let raw = UserDefaults(suiteName: AppLanguagePreference.appGroupIdentifier)?.string(forKey: AppLanguagePreference.sharedDefaultsKey)
        switch AppLanguagePreference.resolve(rawValue: raw) {
        case .korean: return .korean
        case .english: return .english
        }
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "English"
        }
    }

    var locale: Locale {
        switch self {
        case .korean: Locale(identifier: "ko_KR")
        case .english: Locale(identifier: "en_US")
        }
    }

    var dateTitleFormat: String {
        switch self {
        case .korean: "M월 d일 EEEE"
        case .english: "EEE, MMM d"
        }
    }

    var monthTitleFormat: String {
        switch self {
        case .korean: "yyyy년 M월"
        case .english: "MMMM yyyy"
        }
    }

    var datePartFormat: String {
        switch self {
        case .korean: "M월 d일"
        case .english: "MMM d"
        }
    }

    var weekdayFormat: String {
        switch self {
        case .korean: "EEEE"
        case .english: "EEE"
        }
    }

    var resolvedLanguage: AppLanguagePreference.ResolvedLanguage {
        switch self {
        case .korean: .korean
        case .english: .english
        }
    }

    func text(_ korean: String, _ english: String) -> String {
        resolvedLanguage.text(korean, english)
    }
}

enum MapHomeMovementEditOption {
    static let modes: [TravelMode] = [
        .walking,
        .cycling,
        .car,
        .subway,
        .bus,
        .ship,
        .airplane,
        .train,
    ]

    static func mode(
        categoryID: String,
        behavior: String?,
        title: String
    ) -> TravelMode? {
        guard categoryID == "movement" else { return nil }
        if let behavior,
           let mode = TravelMode(rawValue: behavior),
           modes.contains(mode) {
            return mode
        }
        return modes.first {
            MovementPresentation.title(for: $0) == title
                || englishTitle(for: $0) == title
        }
    }

    static func localizedTitle(
        for mode: TravelMode,
        language: MapHomeLanguage
    ) -> String {
        language.text(
            MovementPresentation.title(for: mode),
            englishTitle(for: mode)
        )
    }

    private static func englishTitle(for mode: TravelMode) -> String {
        switch mode {
        case .walking: "Walking"
        case .cycling: "Bicycle"
        case .car: "Car"
        case .subway: "Subway"
        case .bus: "Bus"
        case .ship: "Ship"
        case .airplane: "Airplane"
        case .train: "Train"
        case .running: "Running"
        case .taxi: "Taxi"
        }
    }
}
