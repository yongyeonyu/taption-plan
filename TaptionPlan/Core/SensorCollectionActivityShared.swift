import ActivityKit
import Foundation
import OSLog
import SwiftUI
import TaptionPlanCore

enum SensorCollectionActivityPhase: String, Codable, Hashable {
    case waiting
    case pulse
    case flatline
    case hidden
}

enum SensorCollectionProgressPolicy {
    static func halfWindowDuration(intervalSeconds: Int?) -> TimeInterval? {
        guard let intervalSeconds, intervalSeconds > 0 else { return nil }
        return TimeInterval(intervalSeconds) / 2
    }

    static func progress(
        at date: Date,
        startedAt: Date,
        lastSavedAt: Date?,
        intervalSeconds: Int?
    ) -> Double? {
        guard let duration = halfWindowDuration(intervalSeconds: intervalSeconds),
              duration > 0 else { return nil }
        let cycleStart = lastSavedAt ?? startedAt
        let elapsed = date.timeIntervalSince(cycleStart)
        guard elapsed.isFinite else { return 0 }
        return min(max(elapsed / duration, 0), 1)
    }
}

enum SensorCollectionWaveformMath {
    static func segmentedPosition(
        localPosition: Double,
        offset: Double,
        scale: Double
    ) -> Double {
        offset + min(max(localPosition, 0), 1) * max(scale, 0)
    }

    static func rightToLeftEndpoint(
        progress: Double,
        width: Double
    ) -> Double {
        let clampedProgress = min(max(progress, 0), 1)
        return width * (1 - clampedProgress)
    }

    static func leftToRightEndpoint(
        progress: Double,
        width: Double
    ) -> Double {
        width * min(max(progress, 0), 1)
    }

    static func cycleProgress(
        at date: Date,
        origin: Date,
        duration: TimeInterval
    ) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(origin)
        guard elapsed.isFinite, elapsed >= 0 else { return 0 }
        let progress = (elapsed / duration).truncatingRemainder(dividingBy: 1)
        return progress >= 0 ? progress : progress + 1
    }

    static func rightToLeftPhase(
        position: Double,
        progress: Double
    ) -> Double {
        let value = position - progress
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }

    static func heartbeat(at phase: Double) -> Double {
        guard phase.isFinite else { return 0 }
        let normalizedPhase = phase.truncatingRemainder(dividingBy: 1)
        let wrappedPhase = normalizedPhase >= 0
            ? normalizedPhase
            : normalizedPhase + 1

        func gaussian(center: Double, width: Double, amplitude: Double) -> Double {
            let distance = abs(wrappedPhase - center)
            let wrappedDistance = min(distance, 1 - distance)
            return amplitude * exp(-0.5 * (wrappedDistance / width) * (wrappedDistance / width))
        }

        let value = gaussian(center: 0.18, width: 0.055, amplitude: 0.22)
            + gaussian(center: 0.37, width: 0.018, amplitude: -0.24)
            + gaussian(center: 0.405, width: 0.014, amplitude: 1.05)
            + gaussian(center: 0.44, width: 0.018, amplitude: -0.45)
            + gaussian(center: 0.63, width: 0.075, amplitude: 0.30)
        return min(max(value, -1), 1)
    }
}

struct SensorCollectionActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var lastSavedAt: Date?
        var collectionKinds: [String]
        var isCollecting: Bool
        var intervalSeconds: Int?
        var sessionStateRawValue: String?
        var saveToken: Int?
        var phaseRawValue: String?
        var phaseUntil: Date?
        /// True when the most recent saved sample came from a supported
        /// external device such as Apple Watch. A different app's sensor use
        /// is never inferred.
        var isExternalSample: Bool?
        var latestHeartRate: Double?
        var heartRateUpdatedAt: Date?
        var sensorHUDUntil: Date?
        var currentActivityTitle: String?
        var currentActivityCategoryID: String?
        var currentActivitySystemImage: String?
        var currentActivityCatStyle: String?
        var currentActivityFrame: Int?
        /// 잠금 화면에 보이는 연봉 카운터 글자(예: "53,761원"). 없으면 nil.
        var salaryText: String? = nil
        /// 잠금 화면이 시간에 맞춰 스스로 올리는 연봉 카운터의 기준값(마지막 계산 시점의 오늘 근무 초).
        var salaryBaseSeconds: Double? = nil
        var salaryHourlyRate: Double? = nil
        var salaryMeasuredAt: Date? = nil
        var salaryIsWorking: Bool? = nil
        var salaryTickSeconds: Int? = nil
        /// 금액 통화(ISO). 없으면 원이다.
        var salaryCurrencyCode: String? = nil
        /// 다이나믹 아일랜드 펼침 화면의 오늘 요약. 옛 payload에는 없어 nil이다.
        var daySummary: SensorCollectionDaySummary? = nil

        var phase: SensorCollectionActivityPhase {
            guard let phaseRawValue,
                  let phase = SensorCollectionActivityPhase(
                      rawValue: phaseRawValue
                  ) else {
                return isCollecting ? .waiting : .hidden
            }
            return phase
        }

        init(
            startedAt: Date,
            lastSavedAt: Date?,
            collectionKinds: [String],
            isCollecting: Bool,
            intervalSeconds: Int? = nil,
            sessionStateRawValue: String? = nil,
            saveToken: Int? = nil,
            phaseRawValue: String? = nil,
            phaseUntil: Date? = nil,
            isExternalSample: Bool? = nil,
            latestHeartRate: Double? = nil,
            heartRateUpdatedAt: Date? = nil,
            sensorHUDUntil: Date? = nil,
            currentActivityTitle: String? = nil,
            currentActivityCategoryID: String? = nil,
            currentActivitySystemImage: String? = nil,
            currentActivityCatStyle: String? = nil,
            currentActivityFrame: Int? = nil,
            salaryText: String? = nil,
            salaryBaseSeconds: Double? = nil,
            salaryHourlyRate: Double? = nil,
            salaryMeasuredAt: Date? = nil,
            salaryIsWorking: Bool? = nil,
            salaryTickSeconds: Int? = nil,
            salaryCurrencyCode: String? = nil,
            daySummary: SensorCollectionDaySummary? = nil
        ) {
            self.startedAt = startedAt
            self.lastSavedAt = lastSavedAt
            self.collectionKinds = collectionKinds
            self.isCollecting = isCollecting
            self.intervalSeconds = intervalSeconds
            self.sessionStateRawValue = sessionStateRawValue
            self.saveToken = saveToken
            self.phaseRawValue = phaseRawValue
            self.phaseUntil = phaseUntil
            self.isExternalSample = isExternalSample
            self.latestHeartRate = latestHeartRate
            self.heartRateUpdatedAt = heartRateUpdatedAt
            self.sensorHUDUntil = sensorHUDUntil
            self.currentActivityTitle = currentActivityTitle
            self.currentActivityCategoryID = currentActivityCategoryID
            self.currentActivitySystemImage = currentActivitySystemImage
            self.currentActivityCatStyle = currentActivityCatStyle
            self.currentActivityFrame = currentActivityFrame
            self.salaryText = salaryText
            self.salaryBaseSeconds = salaryBaseSeconds
            self.salaryHourlyRate = salaryHourlyRate
            self.salaryMeasuredAt = salaryMeasuredAt
            self.salaryIsWorking = salaryIsWorking
            self.salaryTickSeconds = salaryTickSeconds
            self.salaryCurrencyCode = salaryCurrencyCode
            self.daySummary = daySummary
        }
    }

    var sessionID: UUID
}

enum SensorCollectionActivityPolicy {
    static let maximumDuration: TimeInterval = 8 * 3_600
    static let pulseDuration: TimeInterval = 1
    static let completionFlatlineDuration: TimeInterval = 1
    static let waveformScanDuration: TimeInterval = 1
    static let sensorHUDDuration: TimeInterval = 10

    static func sensorHUDUntil(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(sensorHUDDuration)
    }

    static func canStart(
        isForeground: Bool,
        intervalSeconds: Int,
        activitiesEnabled: Bool
    ) -> Bool {
        isForeground
            && GPSLoggingPreferences.supportedIntervalSeconds.contains(
                intervalSeconds
            )
            && activitiesEnabled
    }

    static func expirationDate(startedAt: Date) -> Date {
        startedAt.addingTimeInterval(maximumDuration)
    }

    static func isExpired(startedAt: Date, now: Date) -> Bool {
        now >= expirationDate(startedAt: startedAt)
    }

    static func pulseUntil(
        now: Date,
        intervalSeconds: Int? = nil
    ) -> Date {
        let duration = SensorCollectionProgressPolicy
            .halfWindowDuration(intervalSeconds: intervalSeconds)
            ?? pulseDuration
        return now.addingTimeInterval(duration)
    }

    static func completionFlatlineUntil(now: Date) -> Date {
        now.addingTimeInterval(completionFlatlineDuration)
    }

    static func hasNewSavedSample(
        previousSaveToken: Int?,
        currentSaveToken: Int?,
        previousSavedAt: Date?,
        currentSavedAt: Date?
    ) -> Bool {
        if let currentSaveToken {
            guard let previousSaveToken else {
                return previousSavedAt != currentSavedAt
                    && currentSavedAt != nil
            }
            return currentSaveToken > previousSaveToken
        }
        return currentSavedAt != previousSavedAt
            && currentSavedAt != nil
    }

    static func isPhaseExpired(
        _ phase: SensorCollectionActivityPhase,
        until: Date?,
        now: Date
    ) -> Bool {
        guard phase == .pulse, let until else { return false }
        return now >= until
    }
}
