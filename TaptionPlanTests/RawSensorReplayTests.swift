import XCTest
import UIKit
import CoreLocation
import StoreKit
import StoreKitTest
import TaptionPlanCore
@testable import TaptionPlan

/// 기기에서 내보낸 「어제·오늘 센서 원본」을 지금 분류기로 다시 판정해 출력한다(SUB1029A01).
/// `TEST_RUNNER_TAPTION_RAW_REPLAY=<json 경로>`로 실행할 때만 돈다. 판정은 출력만 하고 단정하지 않는다.
final class RawSensorReplayTests: XCTestCase {
    func testReplayExportedRawDays() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_RAW_REPLAY"], !path.isEmpty else {
            throw XCTSkip("TAPTION_RAW_REPLAY 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days: [TodaySensorRawExport]
        if let pair = try? JSONDecoder().decode([TodaySensorRawExport].self, from: data) {
            days = pair
        } else {
            days = [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        for day in days {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            let pressure = readings.filter { $0.pressureKilopascals != nil }.count
            print("REPLAY day \(formatter.string(from: day.day)) readings=\(readings.count) pressure=\(pressure) travel=\(day.travel.count) places=\(day.places?.count ?? -1) actuals=\(day.actuals?.count ?? -1)")
            for stay in (day.places ?? []).sorted(by: { $0.span.start < $1.span.start }) {
                print("REPLAY stay \(formatter.string(from: stay.span.start))–\(formatter.string(from: stay.span.end)) key=\(stay.placeKey.prefix(24)) name=\(stay.displayName) confirmed=\(stay.isConfirmed)")
            }
            for actual in (day.actuals ?? []).sorted(by: { $0.startedAt < $1.startedAt }) where actual.source != .healthKit {
                print("REPLAY actual \(formatter.string(from: actual.startedAt))–\(formatter.string(from: actual.endedAt ?? actual.startedAt)) \(actual.categoryID) src=\(actual.source.rawValue) model=\(actual.modelVersion ?? "-") locked=\(actual.isClassificationLocked ?? false) manual=\(actual.manuallyCorrected)")
            }
            // 원본 표본만으로 역 궤적 엔진이 지하철을 새로 찾는지 본다(EXP1029A02 — 자차 출근에 회색 지하철 경로).
            for detected in SubwayTravelSegmentEngine.segments(from: readings) {
                print("REPLAY detected-subway \(formatter.string(from: detected.span.start))–\(formatter.string(from: detected.span.end)) "
                    + "conf=\(detected.confidence) route=\(detected.subwayRoute?.stops.map(\.stationName).joined(separator: ">") ?? "-") "
                    + "evidence=\(detected.evidence.prefix(6).joined(separator: "|"))")
            }
            for segment in day.travel.sorted(by: { $0.span.start < $1.span.start }) {
                let inside = readings.filter { segment.span.contains($0.timestamp) }
                let around = readings.filter {
                    TravelModeClassifier.altitudeContextSpan(segment.span).contains($0.timestamp)
                }
                let fresh = TravelModeClassifier().classify(readings: inside, inside: segment.span, altitudeContext: around)
                let altitude = TravelModeClassifier.altitudeChangeMeters(around)
                print("REPLAY \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) "
                    + "stored=\(segment.mode.rawValue) fresh=\(fresh.mode.rawValue) altitude=\(Int(altitude.rounded()))m "
                    + "readings=\(inside.count) pressure=\(inside.filter { $0.pressureKilopascals != nil }.count) "
                    + "evidence=\(fresh.evidence.prefix(4).joined(separator: "|"))")
            }
        }
    }

    /// 저장된 이동 구간(예전 규칙)과 분류 패키지 HMM 구간을 분 단위로 맞댄다(RPL1101A01).
    /// `TAPTION_REPLAY_OUT`이 있으면 요약 JSON을 그 경로에 쓴다. 판정은 기록만 하고 단정하지 않는다.
    func testCompareStoredTravelWithClassifierTimeline() throws {
        guard let path = ProcessInfo.processInfo.environment["TAPTION_RAW_REPLAY"], !path.isEmpty else {
            throw XCTSkip("TAPTION_RAW_REPLAY 없음")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let days = try (try? JSONDecoder().decode([TodaySensorRawExport].self, from: data))
            ?? [try JSONDecoder().decode(TodaySensorRawExport.self, from: data)]
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        var report: [[String: Any]] = []
        for day in days {
            let readings = day.readings.sorted { $0.timestamp < $1.timestamp }
            guard let first = readings.first?.timestamp, let last = readings.last?.timestamp, last > first else { continue }
            let span = TimeSpan(start: first, end: last)
            let timeline = try ClassifierAdapter.travelTimeline(readings: readings, in: span)
            func storedMode(_ date: Date) -> String {
                day.travel.first { $0.span.contains(date) }?.mode.rawValue ?? "stationary"
            }
            func hmmMode(_ date: Date) -> String {
                guard let segment = timeline.first(where: { $0.span.contains(date) }) else { return "none" }
                return segment.mode?.rawValue ?? "stationary"
            }
            var confusion: [String: Int] = [:]
            var agree = 0, total = 0
            var minute = first
            while minute < last {
                let mid = minute.addingTimeInterval(30)
                let pair = "\(storedMode(mid))→\(hmmMode(mid))"
                confusion[pair, default: 0] += 1
                // 원본 창이 없는 분(none)은 HMM이 판단하지 않은 시간이라 일치율에서 뺀다.
                if hmmMode(mid) != "none" {
                    if storedMode(mid) == hmmMode(mid) { agree += 1 }
                    total += 1
                }
                minute = minute.addingTimeInterval(60)
            }
            func majority(_ window: TimeSpan) -> (mode: String, share: Double) {
                var counts: [String: TimeInterval] = [:]
                for segment in timeline {
                    guard let overlap = segment.span.intersection(with: window)?.duration, overlap > 0 else { continue }
                    counts[segment.mode?.rawValue ?? "stationary", default: 0] += overlap
                }
                guard let best = counts.max(by: { $0.value < $1.value }), window.duration > 0 else { return ("none", 0) }
                return (best.key, (best.value / window.duration * 100).rounded() / 100)
            }
            let segments: [[String: Any]] = day.travel.sorted { $0.span.start < $1.span.start }.map { segment in
                let inside = readings.filter { segment.span.contains($0.timestamp) }
                let around = readings.filter { TravelModeClassifier.altitudeContextSpan(segment.span).contains($0.timestamp) }
                let fresh = TravelModeClassifier().classify(readings: inside, inside: segment.span, altitudeContext: around)
                let hmm = majority(segment.span)
                print("RPL seg \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) "
                    + "stored=\(segment.mode.rawValue) rule=\(fresh.mode.rawValue) hmm=\(hmm.mode)(\(hmm.share)) readings=\(inside.count)")
                return ["start": formatter.string(from: segment.span.start), "end": formatter.string(from: segment.span.end),
                        "minutes": Int(segment.span.duration / 60), "stored": segment.mode.rawValue,
                        "rule": fresh.mode.rawValue, "hmm": hmm.mode, "hmmShare": hmm.share]
            }
            let extra: [[String: Any]] = timeline.filter { segment in
                segment.mode != nil && segment.span.duration >= 180
                    && !day.travel.contains { $0.span.intersection(with: segment.span) != nil }
            }.map { segment in
                print("RPL hmm-only \(formatter.string(from: segment.span.start))–\(formatter.string(from: segment.span.end)) "
                    + "\(segment.mode?.rawValue ?? "-") score=\(segment.score) m=\(Int(segment.meters))")
                return ["start": formatter.string(from: segment.span.start), "end": formatter.string(from: segment.span.end),
                        "mode": segment.mode?.rawValue ?? "-", "score": segment.score, "meters": Int(segment.meters)]
            }
            let userOwned: [[String: Any]] = (day.actuals ?? []).filter { ActualRecord.userOwned($0) }.map { actual in
                let actualSpan = actual.span(asOf: last)
                let hmm = majority(actualSpan)
                return ["start": formatter.string(from: actualSpan.start), "end": formatter.string(from: actualSpan.end),
                        "category": actual.categoryID, "title": actual.title, "hmm": hmm.mode, "hmmShare": hmm.share]
            }
            let agreement = total > 0 ? (Double(agree) / Double(total) * 1000).rounded() / 10 : 0
            print("RPL day \(formatter.string(from: day.day)) minutes=\(total) agree=\(agreement)% segments=\(timeline.count) userOwned=\(userOwned.count)")
            report.append(["day": formatter.string(from: day.day), "isComplete": day.isComplete, "readings": readings.count,
                           "minutes": total, "agreementPercent": agreement, "confusionMinutes": confusion,
                           "storedSegments": segments, "hmmOnlySegments": extra, "userOwned": userOwned])
        }
        if let out = ProcessInfo.processInfo.environment["TAPTION_REPLAY_OUT"], !out.isEmpty {
            let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: URL(fileURLWithPath: out))
        }
    }
}
