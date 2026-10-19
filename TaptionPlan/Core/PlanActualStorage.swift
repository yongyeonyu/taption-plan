import Foundation
import TaptionPlanCore

struct PlanActualEdit: Sendable {
    let baseline: [ActualRecord]
    let result: [ActualRecord]
    let index: Int

    init?(replacing record: ActualRecord, at index: Int, in baseline: [ActualRecord]) {
        guard baseline.indices.contains(index), baseline[index].id == record.id else { return nil }
        self.baseline = baseline
        self.index = index
        var result = baseline
        result[index] = record
        self.result = result
    }
}

/// 계획 기록 배열의 저장소 공유·바이트 단위 동일성 비교 보조 함수.
enum PlanActualStorage {
    static func reusingUnchangedStorage(_ records: [ActualRecord], previous: [ActualRecord],
                                        cancellationCheck: () throws -> Void) rethrows -> [ActualRecord] {
        guard !sharesStorage(records, previous) else { return previous }
        guard records.count == previous.count else { return records }
        for lower in stride(from: 0, to: records.count, by: 256) {
            try cancellationCheck()
            let upper = min(lower + 256, records.count)
            guard exactlyEqual(records[lower..<upper], previous[lower..<upper]) else { return records }
        }
        return previous
    }

    static func sharesStorage(_ lhs: [ActualRecord], _ rhs: [ActualRecord]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.withUnsafeBufferPointer { a in rhs.withUnsafeBufferPointer { b in a.baseAddress == b.baseAddress } }
    }

    static func exactlyEqual(_ lhs: ArraySlice<ActualRecord>, _ rhs: ArraySlice<ActualRecord>) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { exactlyEqual($0, $1) }
    }

    private static func exactlyEqual(_ a: ActualRecord, _ b: ActualRecord) -> Bool {
        // Value equality plus UTF-8 checks retains canonically equal but byte-distinct edits.
        a == b && exact(a.title, b.title) && exact(a.categoryID, b.categoryID)
            && exact(a.behavior, b.behavior) && exact(a.modelVersion, b.modelVersion)
            && zip(a.evidence, b.evidence).allSatisfy { exact($0, $1) }
            && exact(a.startedAt, b.startedAt) && exact(a.endedAt, b.endedAt)
            && exact(a.createdAt, b.createdAt)
    }

    private static func exact(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case let (.some(a), .some(b)): a.utf8.elementsEqual(b.utf8)
        case (.none, .none): true
        default: false
        }
    }

    private static func exact(_ a: Date?, _ b: Date?) -> Bool {
        a?.timeIntervalSinceReferenceDate.bitPattern == b?.timeIntervalSinceReferenceDate.bitPattern
    }
}
