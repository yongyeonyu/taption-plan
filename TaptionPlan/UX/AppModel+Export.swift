import Foundation
import TaptionPlanCore

struct TodaySensorRawExport: Codable, Sendable {
    let day: Date
    let isComplete: Bool
    let readings: [SensorReading]
    let travel: [TravelSegment]
    /// 머무름·자동 기록도 함께 담아 업무 분류를 기기 밖에서 재판정한다(WRK1029A02). 옛 파일에는 없다.
    var places: [PlaceStay]? = nil
    var actuals: [ActualRecord]? = nil

    static func readings(_ source: [SensorReading], on date: Date,
        calendar: Calendar = .autoupdatingCurrent) -> [SensorReading] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return source.filter { $0.timestamp >= start && $0.timestamp < end }
    }
}


enum DiagnosticsExportStatusKey: Sendable {
    case ready, exporting, exported, failed

    var localized: String {
        switch self {
        case .ready: AppLanguagePreference.text(korean: "준비됨", english: "Ready")
        case .exporting: AppLanguagePreference.text(korean: "전송 중", english: "Exporting")
        case .exported: AppLanguagePreference.text(korean: "전송됨", english: "Exported")
        case .failed: AppLanguagePreference.text(korean: "실패", english: "Failed")
        }
    }
}

extension AppModel {
    func exportTodaySensorRawURL() async throws -> URL {
        let now = Date.now
        // 어제·오늘을 한 파일에 담는다(SUB1029A01 — 어제 지하철·오늘 자동차 대조).
        var payload: [TodaySensorRawExport] = []
        for date in [Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: now) ?? now, now] {
            let day = await planDayDataSnapshot(for: date, forceReload: true, refreshRawReadings: true)
            payload.append(TodaySensorRawExport(day: day.day, isComplete: day.isComplete,
                readings: TodaySensorRawExport.readings(day.readings, on: date), travel: day.travel,
                places: day.places, actuals: day.actuals))
        }
        return try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaptionPlanRawExport", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Taption-Raw-2Days-\(UUID().uuidString).json")
            try JSONEncoder().encode(payload).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }.value
    }

    func exportSnapshotURL() throws -> URL {
        let data = try SnapshotExporter.jsonData(snapshot)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaptionPlanExport", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("Taption-Plan-Data.json")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    /// 어제·오늘 센서 원본을 iCloud Drive › TaptionLogs에 바로 저장하고 결과 문구를 돌려준다(SUB1029A01).
    func exportSensorRawToICloud() async -> String {
        do {
            let url = try await exportTodaySensorRawURL()
            let saved = try await Task.detached(priority: .utility) {
                try TaptionPlanDiagnosticsICloudExporter().export(url, updatesLatest: false)
            }.value
            return AppLanguagePreference.text(korean: "저장됨 · \(saved.lastPathComponent)", english: "Saved · \(saved.lastPathComponent)")
        } catch {
            return AppLanguagePreference.text(korean: "실패 · \(error.localizedDescription)", english: "Failed · \(error.localizedDescription)")
        }
    }

    func exportDiagnosticsToICloud() async {
        guard !isExportingDiagnostics else { return }
        isExportingDiagnostics = true
        diagnosticsExportStatusKey = .exporting
        defer { isExportingDiagnostics = false }
        let logger = TaptionPlanDiagnosticsLogger.shared
        let operation = logger.beginOperation(
            "diagnostics_export",
            fields: ["destination": "icloud_drive"]
        )
        var iphoneLogBytes = 0
        var watchLogBytes = 0
        do {
            logger.record("diagnostics_export_requested")
            let watchLog = await watchConnectivityService
                .requestDiagnosticsLog()
                ?? WatchLaunchReportStore.read()?.report
            let builder = try TaptionPlanDiagnosticsLogPackageBuilder
                .applicationSupport()
            let iphoneLog = logger.combinedLog()
            iphoneLogBytes = iphoneLog.utf8.count
            watchLogBytes = watchLog?.utf8.count ?? 0
            let package = try builder.makePackage(
                summary: diagnosticsSummary,
                iphoneLog: iphoneLog,
                watchLog: watchLog
            )
            let destination = try await Task.detached(priority: .utility) {
                try TaptionPlanDiagnosticsICloudExporter().export(package)
            }.value
            diagnosticsExportStatusKey = .exported
            let defaults = UserDefaults(
                suiteName: TaptionWidgetSharedStore.appGroupIdentifier
            ) ?? .standard
            defaults.set(
                destination.lastPathComponent,
                forKey: Self.diagnosticsLatestFileKey
            )
            defaults.set(
                Date.now,
                forKey: Self.diagnosticsLatestSavedAtKey
            )
            logger.record(
                "diagnostics_export_completed",
                fields: [
                    "file": destination.lastPathComponent,
                    "latest_pointer": TaptionDiagnosticsLatestLogManifest.fileName,
                ]
            )
            logger.finishOperation(
                operation,
                outcome: "success",
                fields: [
                    "file": destination.lastPathComponent,
                    "iphone_log_bytes": String(iphoneLogBytes),
                    "watch_log_bytes": String(watchLogBytes),
                ]
            )
        } catch {
            diagnosticsExportStatusKey = .failed
            logger.finishOperation(
                operation,
                outcome: "failure",
                fields: [
                    "iphone_log_bytes": String(iphoneLogBytes),
                    "watch_log_bytes": String(watchLogBytes),
                ],
                error: error
            )
            logger.record(
                "diagnostics_export_failed",
                level: .error,
                fields: TaptionDiagnosticError.compactFields(for: error)
            )
            userFacingError = error.localizedDescription
        }
    }

    private var diagnosticsSummary: [String: String] {
        let bundle = Bundle.main
        var summary: [String: String] = [
            "app_version": bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "build": bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "plans": String(snapshot.plans.count),
            "actuals": String(snapshot.actuals.count),
            "travel": String(snapshot.travel.count),
            "places": String(snapshot.places.count),
            "weather": String(snapshot.weather.count),
            "calendar_events": String(snapshot.calendarEvents.count),
            "photos": String(snapshot.photos.count),
            "memos": String(snapshot.memos.count),
            "watch_connection": appleWatchConnectionState.rawValue,
            "sensor_collecting": String(isSensorCollecting),
            "sensor_service_available": String(sensorService != nil),
            "sensor_stream_live": String(
                sensorService?.isCollectionLive() == true
            ),
            "sensor_archive_error": sensorStorageErrorDescription
                ?? sensorService?.lastPersistenceErrorDescription
                ?? "none",
            "sensor_latest_persisted_at": sensorService?
                .latestPersistedReadingDate()
                .map { String($0.timeIntervalSince1970) } ?? "none",
            "location_enabled": String(settings.locationEnabled),
            "health_enabled": String(settings.healthEnabled),
            "cloud_status": cloudStatusText,
            "cloud_status_reason": cloudUnavailableReason?
                .statusLabel(preference: .korean) ?? "없음",
            "widget_sync": widgetSyncStatusText,
            "integration_refresh_skipped": String(integrationRefreshSkipCount),
            "widget_payload_skipped": String(widgetPayloadSkipCount),
            "watch_payload_skipped": String(watchPayloadSkipCount),
        ]
        summary.merge(
            TaptionPlanDiagnosticsSession.latestSummary(),
            uniquingKeysWith: { _, new in new }
        )
        summary.merge(
            TaptionPlanDiagnosticsTravelSummary.fields(for: snapshot.travel),
            uniquingKeysWith: { _, new in new }
        )
        return summary
    }
}
