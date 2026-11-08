import Foundation
/// 도메인 모델(`TimeSpan` 등)이 `TaptionPlanCore`에 있어 앱·위젯 파일 전체가 보게 한다.
/// 스냅샷과 저장 모델은 `TaptionStoreRepository.swift`가 `TaptionPlanStore`를 다시 내보낸다.
@_exported import TaptionPlanCore

/// The first product surface is an automatic life log. Manual planning data
/// remains in storage for compatibility, but is intentionally kept out of the
/// primary iPhone and widget surfaces until the automatic timeline is stable.
enum TaptionProductScope {
    static let automaticLoggingOnly = true
}

// MARK: - Shared domain vocabulary

// MARK: - Plan and actual records

// `TimeSpan`은 `TaptionPlanCore/Domain/TimeSpan.swift`에 있다.

// MARK: - Categories and templates

// MARK: - Calendar, photo, health, weather

// MARK: - Location and movement

// MARK: - Summaries, review, widget, and settings

enum WidgetAction: String, Codable, CaseIterable, Sendable {
    case complete
    case postponeThirtyMinutes
    case moveToNextFreeTime
    case stopCurrentActivity
}

// `TaptionDataSnapshot`과 저장 속성 타입은 `TaptionPlanStore/Snapshot/`에 있다.

/// 분류 엔진에도 같은 이름이 있어, 앱에서는 예전처럼 HealthKit 수면 기록(저장소 쪽)을 뜻하게 고정한다.
typealias SleepSession = TaptionPlanStore.SleepSession

// `distanceMeters`·`PlanarDistance`는 `TaptionPlanCore/Domain/GeoPoint.swift`에 있다.
