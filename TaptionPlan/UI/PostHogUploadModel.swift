import Foundation
import Observation

/// 「데이터 보호 › 포스트호그 로그 업로드」의 상태와 흐름(PHG1120A01). 버튼을 누를 때만, 앱이 전면일 때만 보낸다. 자동·백그라운드 전송 없음.
@MainActor
@Observable
final class PostHogUploadModel {
    static let shared = PostHogUploadModel()

    static let consentKey = "plan_posthog_raw_upload_consent"
    static let anonIDKey = "plan_diagnostics_anon_id"
    static let lastResultKey = "plan_posthog_last_result"

    var isUploading = false
    var logStatus = ""
    var rawStatus = ""
    var canRetryLog = false
    var canRetryRaw = false
    @ObservationIgnored var uploader = PostHogDiagnosticsUploader.live
    @ObservationIgnored var configProvider: () -> PostHogConfig? = { PostHogConfig.current }
    @ObservationIgnored private var logJob: PostHogDiagnosticsUploader.Job?
    @ObservationIgnored private var rawJob: PostHogDiagnosticsUploader.Job?
    @ObservationIgnored private var rawSummary = ""

    var config: PostHogConfig? { configProvider() }
    var isConfigured: Bool { config != nil }
    var notConfiguredText: String { AppLanguagePreference.text(korean: "PostHog 키가 설정되지 않았습니다", english: "PostHog key is not set") }

    var hasRawConsent: Bool { UserDefaults.standard.bool(forKey: Self.consentKey) }
    func setRawConsent(_ value: Bool) { UserDefaults.standard.set(value, forKey: Self.consentKey) }

    /// 앱이 만든 무작위 값. IDFV·IDFA·기기 이름·계정은 쓰지 않는다.
    static func anonymousID(defaults: UserDefaults = .standard) -> String {
        if let id = defaults.string(forKey: anonIDKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: anonIDKey)
        return id
    }

    // MARK: 로그

    func uploadLog(model: AppModel) async {
        guard !isUploading, let config else { return }
        isUploading = true; canRetryLog = false
        defer { isUploading = false }
        logStatus = AppLanguagePreference.text(korean: "준비 중…", english: "Preparing…")
        do {
            let watchLog = await model.watchConnectivityService.requestDiagnosticsLog() ?? WatchLaunchReportStore.read()?.report
            let builder = try TaptionPlanDiagnosticsLogPackageBuilder.applicationSupport()
            let package = try builder.makePackageText(summary: model.diagnosticsSummary, iphoneLog: TaptionPlanDiagnosticsLogger.shared.combinedLog(), watchLog: watchLog)
            let session = UUID().uuidString
            let events = PostHogEvents.logEvents(summary: model.diagnosticsSummary, logText: package.text, session: session, config: config,
                                                 distinctID: Self.anonymousID(), now: .now)
            logJob = PostHogDiagnosticsUploader.Job(session: session, events: events)
            Self.noteLocalFile(package.fileURL.lastPathComponent)
            await run(kind: .log, config: config)
        } catch {
            logStatus = AppLanguagePreference.text(korean: "실패 · \(error.localizedDescription)", english: "Failed · \(error.localizedDescription)")
        }
    }

    func retryLog() async {
        guard !isUploading, let config, logJob != nil else { return }
        isUploading = true; canRetryLog = false
        defer { isUploading = false }
        await run(kind: .log, config: config)
    }

    // MARK: 원본

    func uploadRaw(model: AppModel) async {
        guard !isUploading, let config else { return }
        isUploading = true; canRetryRaw = false
        defer { isUploading = false }
        rawStatus = AppLanguagePreference.text(korean: "준비 중…", english: "Preparing…")
        let exports = await model.todaySensorRawExports()
        let session = UUID().uuidString
        let distinctID = Self.anonymousID()
        let prepared = await Self.prepareRaw(exports, session: session, config: config, distinctID: distinctID)
        rawJob = PostHogDiagnosticsUploader.Job(session: session, events: prepared.events)
        rawSummary = prepared.summary
        await run(kind: .raw, config: config)
    }

    func retryRaw() async {
        guard !isUploading, let config, rawJob != nil else { return }
        isUploading = true; canRetryRaw = false
        defer { isUploading = false }
        await run(kind: .raw, config: config)
    }

    /// 「모든 데이터 삭제」가 부른다: 위치 원본 사본(`RawUploads`)·전송 상태 파일·동의·익명 ID·마지막 결과를 지운다.
    func eraseLocalTraces(defaults: UserDefaults = .standard) {
        if let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("TaptionPlan/Diagnostics", isDirectory: true) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("RawUploads", isDirectory: true))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("upload-state.json"))
        }
        for key in [Self.consentKey, Self.anonIDKey, Self.lastResultKey] {
            UserDefaults.standard.removeObject(forKey: key)
            defaults.removeObject(forKey: key)
        }
        logJob = nil; rawJob = nil
        logStatus = ""; rawStatus = ""; canRetryLog = false; canRetryRaw = false
    }

    private enum Kind { case log, raw }

    /// 로컬 사본(원본 JSON, 최근 3개)을 쓰고 이벤트를 만든다. 무거운 일이라 메인 밖에서 한다.
    private nonisolated static func prepareRaw(_ exports: [TodaySensorRawExport], session: String, config: PostHogConfig, distinctID: String) async -> (events: [PostHogEvent], summary: String) {
        if let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TaptionPlan/Diagnostics/RawUploads", isDirectory: true) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            let file = directory.appendingPathComponent("Taption-Raw-2Days-\(stamp)-\(session.prefix(8)).json")
            try? JSONEncoder().encode(exports).write(to: file, options: [.atomic, .completeFileProtection])
            let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent > $1.lastPathComponent }
            for old in files.dropFirst(3) { try? FileManager.default.removeItem(at: old) }
        }
        let raw = PostHogEvents.rawEvents(exports, session: session, config: config, distinctID: distinctID, now: .now)
        let megabytes = String(format: "%.1f", Double(raw.bytes) / 1_048_576)
        let samples = raw.samples.formatted()
        let summary = raw.truncated
            ? AppLanguagePreference.text(korean: "배치 \(raw.batches) · 표본 \(samples) · \(megabytes)MB(압축 전) · 최근 20,000개만 전송",
                                         english: "\(raw.batches) batches · \(samples) samples · \(megabytes)MB (uncompressed) · latest 20,000 only")
            : AppLanguagePreference.text(korean: "배치 \(raw.batches) · 표본 \(samples) · \(megabytes)MB(압축 전)",
                                         english: "\(raw.batches) batches · \(samples) samples · \(megabytes)MB (uncompressed)")
        return (raw.events, summary)
    }

    private func run(kind: Kind, config: PostHogConfig) async {
        var job = (kind == .log ? logJob : rawJob) ?? PostHogDiagnosticsUploader.Job(session: "", events: [])
        let started = Date.now
        let outcome = await uploader.run(&job, config: config) { done, total in
            Task { @MainActor in
                let text = AppLanguagePreference.text(korean: "전송 중 \(done)/\(total)", english: "Sending \(done)/\(total)")
                if kind == .log { PostHogUploadModel.shared.logStatus = text } else { PostHogUploadModel.shared.rawStatus = text }
            }
        }
        if kind == .log { logJob = job } else { rawJob = job }
        let seconds = Date.now.timeIntervalSince(started)
        let text: String
        switch outcome {
        case .success:
            let kb = job.bytes / 1024
            text = kind == .log
                ? AppLanguagePreference.text(korean: "전송됨 · 이벤트 \(job.events.count) · \(kb)KB", english: "Sent · \(job.events.count) events · \(kb)KB")
                : AppLanguagePreference.text(korean: "전송됨 · \(rawSummary)", english: "Sent · \(rawSummary)")
            if kind == .log { logJob = nil } else { rawJob = nil }
        case let .failure(result, _):
            text = PostHogUploadText.failure(result)
            let retry = !PostHogUploadText.isPermanent(result)
            if kind == .log { canRetryLog = retry } else { canRetryRaw = retry }
        }
        if kind == .log { logStatus = text } else { rawStatus = text }
        // 좌표·키 없이 요약만 남긴다. 요청·응답 본문은 남기지 않는다.
        UserDefaults.standard.set(text, forKey: Self.lastResultKey)
        TaptionPlanDiagnosticsLogger.shared.record("posthog_upload", fields: [
            "kind": kind == .log ? "log" : "raw", "events": String(job.events.count), "done": String(job.done.count),
            "bytes": String(job.bytes), "seconds": String(Int(seconds)), "ok": String(outcome == .success(sent: outcome.sentCount)),
        ])
        Self.writeState(job: job, reason: text)
    }

    private static func noteLocalFile(_ name: String) {
        let defaults = UserDefaults(suiteName: TaptionWidgetSharedStore.appGroupIdentifier) ?? .standard
        defaults.set(name, forKey: AppModel.diagnosticsLatestFileKey)
        defaults.set(Date.now, forKey: AppModel.diagnosticsLatestSavedAtKey)
    }

    /// 재시도가 건너뛸 목록과 마지막 사유(키·좌표 없음).
    private static func writeState(job: PostHogDiagnosticsUploader.Job, reason: String) {
        struct State: Codable { var session: String; var done: [String]; var reason: String; var at: Date }
        guard let directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TaptionPlan/Diagnostics", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = State(session: job.session, done: job.done.sorted(), reason: reason, at: .now)
        try? JSONEncoder().encode(state).write(to: directory.appendingPathComponent("upload-state.json"), options: [.atomic, .completeFileProtection])
    }
}

private extension PostHogDiagnosticsUploader.Outcome {
    var sentCount: Int {
        switch self {
        case let .success(sent), let .failure(_, sent): sent
        }
    }
}
