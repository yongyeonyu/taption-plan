import Foundation
import TaptionPlanCore

/// 오분류 교정 표본을 중계 서버 `POST /classifier-samples`로 보낸다(MSC1119B01).
/// 사용자가 미리보기를 보고 「보내기」를 누를 때만 부른다. 옵트인이 꺼져 있으면 보내지 않는다.
/// 보낸 표본은 기기에서 비운다: 서버가 같은 `id`를 무시하고, 곁 파일에는 「보냄」 표시를 둘 열이 없어 남기면 상한(5,000건)만 차지한다.
/// 서버가 받은(201) 묶음은 거절된 표본까지 비운다(허용 목록에 안 맞는 표본은 다시 보내도 같은 결과다).
@MainActor
enum MisclassificationUploader {
    enum Failure: Equatable {
        case disabled
        case locked
        case notReady
        case offline
        case dailyLimit
        case server(Int)
    }

    struct Result: Equatable {
        var accepted = 0
        var duplicates = 0
        var rejected = 0
        /// 기기에서 비운 건수.
        var removed = 0
        var failure: Failure?

        var sent: Int { accepted + duplicates + rejected }
    }

    struct Preview: Equatable {
        var total: Int
        var activity: Int
        var travel: Int
        var ruleVersion: String
        /// 보낼 표본 가운데 최근 몇 건의 요약 줄.
        var lines: [String]
        /// 보낼 표본 한 건의 실제 JSON(키 순서 고정, 들여쓰기). 없으면 빈 문자열.
        var example: String
    }

    /// 한 번에 보내는 건수. 서버 한도(`maxSamples` 200·1MB)와 같다.
    static let batchSize = 200

    static func preview(_ samples: [MisclassificationSample], ruleVersion: String, lineLimit: Int = 5) -> Preview {
        let lines = samples.suffix(lineLimit).reversed().map { sample in
            let minute = sample.minuteOfDay
            let time = String(format: "%02d:%02d", minute / 60, minute % 60)
            return "\(time) · \(max(1, sample.durationSeconds / 60))m · \(sample.predicted) → \(sample.corrected)"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let example = samples.last.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return Preview(
            total: samples.count,
            activity: samples.filter { $0.kind == .activity }.count,
            travel: samples.filter { $0.kind == .travel }.count,
            ruleVersion: ruleVersion, lines: Array(lines), example: example
        )
    }

    static func send(collector: MisclassificationCollector, env: AssistantRegistration.Environment = .live) async -> Result {
        var result = Result()
        guard collector.isEnabled else { result.failure = .disabled; return result }
        guard !env.client().locked else { result.failure = .locked; return result }
        let all = collector.samples()
        guard !all.isEmpty else { return result }
        guard await AssistantRegistration.prepare(env), let master = env.secrets.read(.master) else { result.failure = .notReady; return result }
        for start in stride(from: 0, to: all.count, by: batchSize) {
            let batch = Array(all[start..<min(start + batchSize, all.count)])
            let body = MisclassificationSample.exportData(batch, ruleVersion: ClassificationRules.version)
            let request = TripRelay.relayRequest("/classifier-samples", method: "POST", body: body, token: master, host: env.host, client: env.client())
            guard let reply = await TripRelay.send(request, session: env.session) else { result.failure = .offline; return result }
            switch reply.status {
            case 201:
                let counts = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
                result.accepted += counts?["accepted"] as? Int ?? 0
                result.duplicates += counts?["duplicates"] as? Int ?? 0
                result.rejected += counts?["rejected"] as? Int ?? 0
                result.removed += collector.remove(ids: Set(batch.map(\.id)))
            case 429:
                result.failure = .dailyLimit
                return result
            default:
                result.failure = .server(reply.status)
                return result
            }
        }
        return result
    }
}
