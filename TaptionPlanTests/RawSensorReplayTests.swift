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
}
