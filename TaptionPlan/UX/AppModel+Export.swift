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
    /// 어제·오늘 센서 원본 자료(PHG1120A01: 만들기와 파일 쓰기를 나눴다).
    func todaySensorRawExports() async -> [TodaySensorRawExport] {
        let now = Date.now
        // 어제·오늘을 한 파일에 담는다(SUB1029A01 — 어제 지하철·오늘 자동차 대조).
        var payload: [TodaySensorRawExport] = []
        for date in [Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: now) ?? now, now] {
            let day = await planDayDataSnapshot(for: date, forceReload: true, refreshRawReadings: true)
            payload.append(TodaySensorRawExport(day: day.day, isComplete: day.isComplete,
                readings: TodaySensorRawExport.readings(day.readings, on: date), travel: day.travel,
                places: day.places, actuals: day.actuals.map { actual in
                    // 개발자에게 보내는 원본에는 구글·기기 일정 제목을 넣지 않는다(GOO1106A01).
                    var safe = actual
                    // 예전에 저장된 근거의 기기 이름(사람 이름이 든 것)도 가린다(WSN1112A02).
                    safe.evidence = HealthSourcePrivacy.sanitized(CalendarTitleClassification.withoutCalendarTitleEvidence(actual.evidence))
                    return safe
                }))
        }
        return payload
    }

    func exportTodaySensorRawURL() async throws -> URL {
        let payload = await todaySensorRawExports()
        return try await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TaptionPlanRawExport", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Taption-Raw-2Days-\(UUID().uuidString).json")
            try JSONEncoder().encode(payload).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }.value
    }

    #if DEBUG
    /// 개발 기기에서 `-exportRawOnLaunch`로 켜면 원본을 앱 임시 폴더에 남긴다. USB로 꺼내 재생 판정을 재현한다.
    func exportRawOnLaunchIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-exportRawOnLaunch") else { return }
        do {
            let url = try await exportTodaySensorRawURL()
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: url.path)
            let places = url.deletingLastPathComponent().appendingPathComponent("frequent-places.json")
            try JSONEncoder().encode(snapshot.settings.frequentPlaces).write(to: places, options: .atomic)
            TaptionPlanDiagnosticsLogger.shared.record("raw_export_done", fields: ["file": url.lastPathComponent])
        } catch {
            TaptionPlanDiagnosticsLogger.shared.record("raw_export_failed", fields: ["error": String(describing: error)])
        }
    }
    #endif

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

    /// 개발자에게 보낼 진단 패키지(MAL1103A01). iCloud에 올리는 것과 같은 내용이다.
    func diagnosticsPackageURL() async throws -> URL {
        let watchLog = await watchConnectivityService.requestDiagnosticsLog() ?? WatchLaunchReportStore.read()?.report
        return try TaptionPlanDiagnosticsLogPackageBuilder.applicationSupport().makePackage(
            summary: diagnosticsSummary,
            iphoneLog: TaptionPlanDiagnosticsLogger.shared.combinedLog(),
            watchLog: watchLog
        )
    }

    /// 네트워크 없이 로컬 진단 패키지만 만든다(무인 벤치용, PHG1120A01). USB로 꺼내 본다.
    func makeDiagnosticsPackageLocally() async {
        let logger = TaptionPlanDiagnosticsLogger.shared
        do {
            _ = try await diagnosticsPackageURL()
            logger.record("diagnostics_package_local")
        } catch {
            logger.record("diagnostics_package_failed", level: .error, fields: TaptionDiagnosticError.compactFields(for: error))
        }
    }

    var diagnosticsSummary: [String: String] {
        let bundle = Bundle.main
        var summary: [String: String] = [
            "app_version": bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
            "build": bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "device_model": TaptionPlanDeviceModel.identifier,
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
