import Foundation
import MetricKit

enum TaptionTerminationDiagnosticFields {
    static func make(reason: String?, exceptionType: NSNumber?, exceptionCode: NSNumber?, signal: NSNumber?) -> [String: String] {
        let reason = String((reason ?? "").prefix(512))
        func token(_ pattern: String) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: reason, range: NSRange(reason.startIndex..., in: reason)),
                  let range = Range(match.range(at: 1), in: reason) else { return "unknown" }
            return String(reason[range])
        }
        return [
            "termination_namespace": token("Namespace\\s+([A-Z_0-9]+)"),
            "termination_code": token("Code\\s+(0x[0-9a-fA-F]+|[0-9]+)"),
            "exception_type": exceptionType?.stringValue ?? "none",
            "exception_code": exceptionCode?.stringValue ?? "none",
            "signal": signal?.stringValue ?? "none",
        ]
    }
}

/// Keep only system counters/codes; exception text and call stacks can contain user data.
final class TaptionPlanSystemDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = TaptionPlanSystemDiagnostics()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let background = exits.backgroundExitData
            let fields: [String: String] = [
                "interval_start": String(payload.timeStampBegin.timeIntervalSince1970),
                "interval_end": String(payload.timeStampEnd.timeIntervalSince1970),
                "application_version": payload.latestApplicationVersion,
                "multiple_versions": String(payload.includesMultipleApplicationVersions),
                "background_normal": String(background.cumulativeNormalAppExitCount),
                "background_memory_limit": String(background.cumulativeMemoryResourceLimitExitCount),
                "background_memory_pressure": String(background.cumulativeMemoryPressureExitCount),
                "background_cpu_limit": String(background.cumulativeCPUResourceLimitExitCount),
                "background_watchdog": String(background.cumulativeAppWatchdogExitCount),
                "background_locked_file": String(background.cumulativeSuspendedWithLockedFileExitCount),
                "background_task_timeout": String(background.cumulativeBackgroundTaskAssertionTimeoutExitCount),
                "background_bad_access": String(background.cumulativeBadAccessExitCount),
                "background_abnormal": String(background.cumulativeAbnormalExitCount),
                "background_illegal_instruction": String(background.cumulativeIllegalInstructionExitCount),
                "foreground_memory_limit": String(exits.foregroundExitData.cumulativeMemoryResourceLimitExitCount),
                "foreground_watchdog": String(exits.foregroundExitData.cumulativeAppWatchdogExitCount),
            ]
            TaptionPlanDiagnosticsLogger.shared.record("system_app_exit_metrics", fields: fields)
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let interval: [String: String] = [
                "interval_start": String(payload.timeStampBegin.timeIntervalSince1970),
                "interval_end": String(payload.timeStampEnd.timeIntervalSince1970),
            ]
            for crash in payload.crashDiagnostics ?? [] {
                let codes = TaptionTerminationDiagnosticFields.make(reason: crash.terminationReason,
                    exceptionType: crash.exceptionType, exceptionCode: crash.exceptionCode, signal: crash.signal)
                TaptionPlanDiagnosticsLogger.shared.record("system_crash_diagnostic", level: .error,
                    fields: interval.merging(codes) { _, value in value })
            }
            let counts: [String: String] = [
                "crashes": String(payload.crashDiagnostics?.count ?? 0),
                "hangs": String(payload.hangDiagnostics?.count ?? 0),
                "cpu_exceptions": String(payload.cpuExceptionDiagnostics?.count ?? 0),
                "disk_write_exceptions": String(payload.diskWriteExceptionDiagnostics?.count ?? 0),
            ]
            TaptionPlanDiagnosticsLogger.shared.record("system_diagnostic_counts", fields: interval.merging(counts) { _, value in value })
        }
    }
}
