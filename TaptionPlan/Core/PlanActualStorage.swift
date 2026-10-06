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

/// Typed SQLite rows preserve record order and provenance, including duplicate IDs.
enum PlanActualStorage {
    struct NativeHeader: Codable, Sendable {
        let format: String
        let count: Int
        init(count: Int) { self.format = "native-actuals-v1"; self.count = count }
    }

    struct Delta: Sendable {
        let rows: [TaptionPlanDayStore.ActualRow]
        let deletedKeys: [String]
        let keys: [String]
        let replaceAll: Bool
        let comparedRecords: Int
    }

    static func nativeHeader(_ payload: Data) throws -> NativeHeader {
        let value = try decode(NativeHeader.self, from: payload)
        guard value.format == "native-actuals-v1", value.count >= 0 else {
            throw TaptionPlanCanonicalStorageError.invalidPayload
        }
        return value
    }

    static func keys(for records: [ActualRecord]) -> [String] {
        var occurrences: [UUID: Int] = [:]
        return records.map { record in
            let occurrence = occurrences[record.id, default: 0]
            occurrences[record.id] = occurrence + 1
            return record.id.uuidString + ":" + String(occurrence)
        }
    }

    static func delta(_ records: [ActualRecord], previous: [ActualRecord]?, previousKeys: [String], edit: PlanActualEdit?) throws -> Delta {
        if let edit, let previous,
           sharesStorage(records, edit.result), sharesStorage(previous, edit.baseline),
           previousKeys.count == records.count {
            let key = previousKeys[edit.index]
            var evidenceCache: [[Data]: Data] = [:]
            let row = try row(records[edit.index], key: key, position: edit.index, evidenceCache: &evidenceCache)
            return Delta(rows: [row], deletedKeys: [], keys: previousKeys, replaceAll: false, comparedRecords: 1)
        }
        guard let previous else {
            return Delta(rows: [], deletedKeys: [], keys: keys(for: records), replaceAll: true, comparedRecords: 0)
        }
        let sameLayout = previous.count == records.count && previousKeys.count == records.count
            && zip(records, previous).allSatisfy { $0.id == $1.id }
        let keys = sameLayout ? previousKeys : keys(for: records)
        let previousIndices = sameLayout ? [:] : Dictionary(uniqueKeysWithValues: previousKeys.enumerated().map { ($0.element, $0.offset) })
        var rows: [TaptionPlanDayStore.ActualRow] = []
        var evidenceCache: [[Data]: Data] = [:]
        for index in records.indices {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if let oldIndex = sameLayout ? index : previousIndices[keys[index]],
               oldIndex == index,
               exactlyEqual(records[index], previous[oldIndex]) { continue }
            rows.append(try row(records[index], key: keys[index], position: index, evidenceCache: &evidenceCache))
        }
        let surviving = sameLayout ? Set<String>() : Set(keys)
        return Delta(rows: rows, deletedKeys: sameLayout ? [] : previousKeys.filter { !surviving.contains($0) }, keys: keys,
                     replaceAll: false, comparedRecords: records.count)
    }

    static func write(_ delta: Delta, records: [ActualRecord], to store: isolated TaptionPlanDayStore) throws {
        guard delta.replaceAll else {
            try store.applyActualRecordDelta(upserting: delta.rows, deletingKeys: delta.deletedKeys)
            return
        }
        if records.isEmpty, try store.actualRecordCount() == 0 { return }
        try store.replaceActualRecords { store in
            // Bulk imports materialize only a small batch of SQLite bindings at a time.
            var evidenceCache: [[Data]: Data] = [:]
            for lower in stride(from: 0, to: records.count, by: 512) {
                try Task.checkCancellation()
                let upper = min(lower + 512, records.count)
                let rows = try (lower..<upper).map {
                    try row(records[$0], key: delta.keys[$0], position: $0, evidenceCache: &evidenceCache)
                }
                try store.applyActualRecordDelta(upserting: rows, deletingKeys: [])
            }
        }
    }

    static func records(from rows: [TaptionPlanDayStore.ActualRow]) throws -> [ActualRecord] {
        var evidenceCache: [Data: [String]] = [:]
        return try rows.enumerated().map { index, row in
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let id = UUID(uuidString: row.id), let source = ActualSource(rawValue: row.source),
                  let confidence = ConfidenceLevel(rawValue: row.confidence) else {
                throw TaptionPlanCanonicalStorageError.invalidPayload
            }
            func uuid(_ value: String?) throws -> UUID? {
                guard let value else { return nil }
                guard let id = UUID(uuidString: value) else { throw TaptionPlanCanonicalStorageError.invalidPayload }
                return id
            }
            let evidence: [String]
            if let cached = evidenceCache[row.evidence] { evidence = cached }
            else {
                evidence = try decode([String].self, from: row.evidence)
                if evidenceCache.count < 128 { evidenceCache[row.evidence] = evidence }
            }
            return try ActualRecord(id: id, planID: uuid(row.planID), routineID: uuid(row.routineID),
                title: row.title, categoryID: row.categoryID, startedAt: row.startedAt, endedAt: row.endedAt,
                source: source, confidence: confidence, createdAt: row.createdAt, behavior: row.behavior,
                evidence: evidence, routeID: uuid(row.routeID), sensorChunkID: uuid(row.sensorChunkID),
                modelVersion: row.modelVersion, manuallyCorrected: row.manuallyCorrected,
                isClassificationLocked: row.classificationLocked)
        }
    }

    private static func row(_ record: ActualRecord, key: String, position: Int,
                            evidenceCache: inout [[Data]: Data]) throws -> TaptionPlanDayStore.ActualRow {
        let evidenceKey = record.evidence.map { Data($0.utf8) }
        let evidence: Data
        if let cached = evidenceCache[evidenceKey] { evidence = cached }
        else {
            evidence = try encode(record.evidence)
            if evidenceCache.count < 128 { evidenceCache[evidenceKey] = evidence }
        }
        return .init(key: key, position: position, id: record.id.uuidString,
            planID: record.planID?.uuidString, routineID: record.routineID?.uuidString,
            title: record.title, categoryID: record.categoryID, startedAt: record.startedAt, endedAt: record.endedAt,
            source: record.source.rawValue, confidence: record.confidence.rawValue, createdAt: record.createdAt,
            behavior: record.behavior, evidence: evidence, routeID: record.routeID?.uuidString,
            sensorChunkID: record.sensorChunkID?.uuidString, modelVersion: record.modelVersion,
            manuallyCorrected: record.manuallyCorrected, classificationLocked: record.isClassificationLocked)
    }

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

    static let domain = "plan.actuals"
    static func decode<Value: Decodable>(_ type: Value.Type, from payload: Data) throws -> Value {
        try TaptionPlanCanonicalStorage.decode(type, from: TaptionPlanCanonicalStorage.encodedPayload(from: payload))
    }

    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        TaptionPlanCanonicalStorage.envelope(for: try TaptionPlanCanonicalStorage.encode(value))
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
