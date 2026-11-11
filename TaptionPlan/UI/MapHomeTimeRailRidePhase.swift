import Foundation

/// 이동 기록(TravelSegment)으로만 채운 탑승 조각 가운데, 같은 수단의 동작 기록 바로 뒤에 붙은 것은 내린 뒤
/// (주차·걸어 나오기)다. 「자동차 탑승」 대신 「자동차 하차」로 보인다(RDE1111A01, 대표 지시).
extension MapHomeTimeRailSegmentEngine {
    static let rideSuffix = " 탑승"
    static let alightSuffix = " 하차"

    static func labelingAlighting(_ segments: [MapHomeTimeRailSegment]) -> [MapHomeTimeRailSegment] {
        var result = segments
        for index in result.indices.dropFirst() {
            let piece = result[index], before = result[index - 1]
            guard piece.categoryID == "movement", piece.title.hasSuffix(rideSuffix),
                  before.categoryID == "movement", before.endMinute == piece.startMinute,
                  before.behavior == piece.behavior, !before.title.hasSuffix(rideSuffix), !before.title.hasSuffix(alightSuffix)
            else { continue }
            var relabeled = MapHomeTimeRailSegment(
                startMinute: piece.startMinute, endMinute: piece.endMinute, categoryID: piece.categoryID,
                title: String(piece.title.dropLast(rideSuffix.count)) + alightSuffix,
                behavior: piece.behavior, sourceIDs: piece.sourceIDs
            )
            relabeled.walkSpans = piece.walkSpans
            relabeled.tripStatus = piece.tripStatus
            result[index] = relabeled
        }
        return result
    }
}
