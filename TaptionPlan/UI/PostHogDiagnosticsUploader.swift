import CryptoKit
import Foundation

/// PostHog 접속 정보(PHG1120A01). 키는 앱 코드·커밋되는 파일에 두지 않고 `AppSecrets.local.xcconfig` → Info.plist로만 들어온다.
struct PostHogConfig: Equatable, Sendable {
    let host: String
    let apiKey: String

    /// 비었거나 `$(`가 남은 값이면 없는 것으로 본다.
    static func from(info: [String: Any]?) -> PostHogConfig? {
        func value(_ key: String) -> String? {
            guard let text = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.contains("$(") else { return nil }
            return text
        }
        guard let key = value("POSTHOG_API_KEY") else { return nil }
        return PostHogConfig(host: value("POSTHOG_HOST") ?? "us.i.posthog.com", apiKey: key)
    }

    static var current: PostHogConfig? { from(info: Bundle.main.infoDictionary) }
}

enum PostHogSendResult: Equatable, Sendable {
    case ok
    case http(Int, String)
    case network(String)
}

/// 이벤트 하나를 요청 본문(JSON, 압축 전)까지 만들어 둔 것. 요청 하나에 하나씩 보낸다(재시도가 성공분을 건너뛰게).
struct PostHogEvent: Sendable {
    let name: String
    let insertID: String
    let body: Data
}

/// 이벤트 만들기(순수). 좌표는 원본 배치에만 들어가고, 로그 이벤트에는 요약·로그 글만 들어간다.
enum PostHogEvents {
    static let app = "bokki-plan"
    static let logChunkBytes = 200 * 1024
    static let rawBatchSamples = 500
    static let rawBatchBytes = 256 * 1024
    static let rawMaxSamples = 20_000

    /// 줄 경계에서 자른다. 조각을 이어 붙이면 원문과 같다.
    static func chunks(of text: String, maxBytes: Int = logChunkBytes) -> [String] {
        var result: [String] = [], current = "", size = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let piece = String(line) + "\n"
            let bytes = piece.utf8.count
            if size + bytes > maxBytes, !current.isEmpty { result.append(current); current = ""; size = 0 }
            if bytes > maxBytes { // 한 줄이 상한보다 길면 글자 단위로 자른다.
                var part = "", used = 0
                for character in piece {
                    let n = String(character).utf8.count
                    if used + n > maxBytes { result.append(part); part = ""; used = 0 }
                    part.append(character); used += n
                }
                current = part; size = used
                continue
            }
            current += piece; size += bytes
        }
        if !current.isEmpty { result.append(current) }
        // 마지막에 붙인 줄바꿈은 원문에 없으므로 뗀다.
        if !text.hasSuffix("\n"), var last = result.popLast() { last.removeLast(); result.append(last) }
        return result
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 요청 본문. `distinct_id`는 앱이 만든 무작위 값이고 사람 프로필은 만들지 않는다. 시각은 ISO 8601.
    static func body(name: String, insertID: String, properties: [String: Any], config: PostHogConfig, distinctID: String, now: Date) -> Data {
        var props = properties
        props["distinct_id"] = distinctID
        props["$process_person_profile"] = false
        props["$insert_id"] = insertID
        props["app"] = app
        let object: [String: Any] = ["api_key": config.apiKey, "batch": [["event": name, "properties": props,
                                                                           "timestamp": ISO8601DateFormatter().string(from: now)]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    static func logEvents(summary: [String: String], logText: String, session: String, config: PostHogConfig, distinctID: String, now: Date) -> [PostHogEvent] {
        let parts = chunks(of: logText)
        return parts.enumerated().map { index, part in
            var props: [String: Any] = ["source": "diagnostics", "session_id": session, "chunk": index, "chunks": parts.count,
                                        "chunk_bytes": part.utf8.count, "sha256": sha256(part), "log_text": part]
            if index == 0 { for (key, value) in summary { props[key] = value } }
            let id = "\(session)-log-\(index)"
            return PostHogEvent(name: "plan_diagnostics_log", insertID: id, body: body(name: "plan_diagnostics_log", insertID: id, properties: props, config: config, distinctID: distinctID, now: now))
        }
    }

    struct Raw {
        var events: [PostHogEvent]
        var batches: Int
        var samples: Int
        var truncated: Bool
        var bytes: Int
    }

    /// 어제·오늘 원본 → 날짜별 요약 이벤트 + 표본 배치 이벤트(표본 500개 / 256KB 중 먼저 닿는 쪽). 표본이 20,000개를 넘으면 최근 것만.
    static func rawEvents(_ exports: [TodaySensorRawExport], session: String, config: PostHogConfig, distinctID: String, now: Date) -> Raw {
        let encoder = JSONEncoder() // 앱이 원본 JSON을 쓰는 기본 인코딩과 같게 둔다(재생 시험이 읽는 모양).
        func object<T: Encodable>(_ value: T) -> Any? {
            (try? encoder.encode(value)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        // 날짜 순서대로 펼친 표본에서 최근 상한만 남긴다.
        var flat: [(day: Int, reading: SensorReading)] = []
        for (index, export) in exports.enumerated() { for reading in export.readings { flat.append((index, reading)) } }
        let truncated = flat.count > rawMaxSamples
        if truncated { flat = Array(flat.suffix(rawMaxSamples)) }

        var batches: [(day: Int, samples: [Any], bytes: Int)] = []
        var samples: [Any] = [], bytes = 0, currentDay = -1, totalBytes = 0
        func flush() {
            if !samples.isEmpty { batches.append((currentDay, samples, bytes)) }
            samples = []; bytes = 0
        }
        for item in flat {
            if item.day != currentDay { flush(); currentDay = item.day }
            guard let sample = object(item.reading), let data = try? JSONSerialization.data(withJSONObject: sample) else { continue }
            if !samples.isEmpty, samples.count >= rawBatchSamples || bytes + data.count > rawBatchBytes { flush() }
            samples.append(sample); bytes += data.count; totalBytes += data.count
        }
        flush()

        let stamp = ISO8601DateFormatter()
        var events: [PostHogEvent] = []
        // 날짜별 요약(이동·방문 장소·활동 기록은 그대로). 이벤트 하나가 1MB를 넘지 않게 날짜마다 따로 만든다.
        for (index, export) in exports.enumerated() {
            var props: [String: Any] = ["source": "sensor_raw", "session_id": session, "day": stamp.string(from: export.day), "days": exports.count,
                                        "day_complete": export.isComplete, "samples_total": flat.count, "batches_total": batches.count,
                                        "truncated": truncated, "raw_bytes_uncompressed": totalBytes]
            if let travel = object(export.travel) { props["travel"] = travel }
            if let places = export.places.flatMap({ object($0) }) { props["places"] = places }
            if let actuals = export.actuals.flatMap({ object($0) }) { props["actuals"] = actuals }
            let id = "\(session)-raw-meta-\(index)"
            events.append(PostHogEvent(name: "plan_diagnostics_raw_meta", insertID: id, body: body(name: "plan_diagnostics_raw_meta", insertID: id, properties: props, config: config, distinctID: distinctID, now: now)))
        }
        for (index, batch) in batches.enumerated() {
            let props: [String: Any] = ["source": "sensor_raw", "session_id": session, "batch": index, "batches": batches.count, "samples_count": batch.samples.count,
                                        "day": stamp.string(from: exports[batch.day].day), "bytes": batch.bytes, "samples": batch.samples]
            let id = "\(session)-raw-\(index)"
            events.append(PostHogEvent(name: "plan_diagnostics_raw_batch", insertID: id, body: body(name: "plan_diagnostics_raw_batch", insertID: id, properties: props, config: config, distinctID: distinctID, now: now)))
        }
        return Raw(events: events, batches: batches.count, samples: flat.count, truncated: truncated, bytes: totalBytes)
    }
}

/// 보내기 결과를 화면 문구로. 응답 사유는 감싸지 않고 그대로 보인다.
enum PostHogUploadText {
    static func failure(_ result: PostHogSendResult) -> String {
        switch result {
        case .ok: return ""
        case let .network(reason):
            return AppLanguagePreference.text(korean: "실패 · \(reason)", english: "Failed · \(reason)")
        case let .http(code, body):
            let detail = body.isEmpty ? "" : " (\(body.prefix(300)))"
            switch code {
            case 429: return AppLanguagePreference.text(korean: "한도 초과로 거절됨(429) · 나중에 다시\(detail)", english: "Rate limited (429) · try again later\(detail)")
            case 402, 403: return AppLanguagePreference.text(korean: "한도·결제로 거절됨(\(code))\(detail)", english: "Rejected for quota or billing (\(code))\(detail)")
            default: return AppLanguagePreference.text(korean: "실패 · \(code)\(detail)", english: "Failed · \(code)\(detail)")
            }
        }
    }

    /// 다시 시도해도 같은 결과인 응답(재시도 단추를 숨긴다).
    static func isPermanent(_ result: PostHogSendResult) -> Bool {
        if case let .http(code, _) = result { return [400, 401, 413].contains(code) }
        return false
    }
}

/// 보내기. 전송은 주입받아 시험이 네트워크를 타지 않는다. 요청·응답 본문은 어디에도 남기지 않는다.
struct PostHogDiagnosticsUploader: Sendable {
    typealias Send = @Sendable (_ body: Data, _ config: PostHogConfig) async -> PostHogSendResult

    var send: Send

    /// 진행 중인 묶음. `done`에 든 이벤트는 재시도에서 건너뛴다.
    struct Job: Sendable {
        var session: String
        var events: [PostHogEvent]
        var done: Set<String> = []
        var bytes: Int { events.reduce(0) { $0 + $1.body.count } }
    }

    enum Outcome: Equatable, Sendable {
        case success(sent: Int)
        case failure(PostHogSendResult, sent: Int)
    }

    func run(_ job: inout Job, config: PostHogConfig, progress: @Sendable (Int, Int) -> Void = { _, _ in }) async -> Outcome {
        var sent = 0
        progress(job.done.count, job.events.count)
        for event in job.events where !job.done.contains(event.insertID) {
            let result = await send(event.body, config)
            guard result == .ok else { return .failure(result, sent: sent) }
            job.done.insert(event.insertID)
            sent += 1
            progress(job.done.count, job.events.count)
        }
        return .success(sent: sent)
    }

    /// 실제 전송: `POST https://<host>/batch/`, gzip 본문. 요청·응답은 기록하지 않는다.
    static let live = PostHogDiagnosticsUploader { body, config in
        guard let url = URL(string: "https://\(config.host)/batch/"), let gz = try? TaptionLogGzip.compress(body) else { return .network("요청을 만들지 못했습니다") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
        request.httpBody = gz
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
            if code == 200, text.contains("Ok") || text.isEmpty { return .ok }
            return .http(code, text)
        } catch {
            return .network((error as NSError).localizedDescription)
        }
    }
}
