import CryptoKit
import Foundation
import TaptionPlanCore

enum PlanDailyBackupSchedule {
    static func calendar(timeZone: TimeZone = .autoupdatingCurrent) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func isDayKey(_ key: String) -> Bool {
        guard let day = TaptionPlanDayKey(storageKey: key), day.month <= 12 else { return false }
        let calendar = calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
        guard let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day)) else { return false }
        return self.key(for: date, calendar: calendar) == key
    }

    static func span(for day: Date, calendar: Calendar) -> TimeSpan {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return TimeSpan(start: start, end: end)
    }
}

/// Small authenticated receipts let completed days skip archive reads and decoding.
/// They are written only after both archive bodies have been committed and checked.
struct PlanDailyBackupCompletion: Codable, Equatable {
    let dayKey: String
    let closedAt: Date
    let createdAt: Date
    let snapshotGenerationID: UUID
    let rawGenerationID: UUID?

    var path: PlanCloudBackupPath {
        PlanCloudBackupPath(monthKey: dayKey, snapshotGenerationID: snapshotGenerationID, createdAt: createdAt)
    }

    private struct Signed: Codable {
        let body: Data
        let authenticationCode: Data
    }

    func encoded(accountKey: Data) throws -> Data {
        guard accountKey.count == 32 else { throw PlanSecurityError.accountUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let body = try encoder.encode(self)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: accountKey)))
        return try JSONEncoder().encode(Signed(body: body, authenticationCode: signature))
    }

    static func decode(_ data: Data, accountKey: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard data.count <= 16_384, accountKey.count == 32,
              let signed = try? JSONDecoder().decode(Signed.self, from: data),
              HMAC<SHA256>.isValidAuthenticationCode(signed.authenticationCode, authenticating: signed.body,
                  using: SymmetricKey(data: accountKey)),
              let value = try? decoder.decode(Self.self, from: signed.body),
              PlanDailyBackupSchedule.isDayKey(value.dayKey),
              value.createdAt >= value.closedAt else { throw PlanSecurityError.invalidArchive }
        return value
    }
}

struct PlanDailyBackupPreparation {
    let days: [Date]
    let skippedDays: Int
    let now: Date
    let calendar: Calendar
    let accountKey: Data
    let verifier: PlanPINVerifier
    let preparationRevision: UInt64
    let dataGeneration: UInt64
}

/// Each dated record belongs to every calendar day it intersects. Keeping the whole
/// value preserves overnight records; restore deduplicates them by their existing IDs.
enum PlanDailyBackupPartition {
    static func combine(legacy: TaptionDataSnapshot?, daily: [TaptionDataSnapshot], metadata: TaptionDataSnapshot) -> TaptionDataSnapshot {
        let snapshots = (legacy.map { [$0] } ?? []) + daily
        func rows<Value: Identifiable>(_ field: KeyPath<TaptionDataSnapshot, [Value]>) -> [Value] {
            var seen = Set<Value.ID>()
            return snapshots.reversed().flatMap { $0[keyPath: field] }.filter { seen.insert($0.id).inserted }
        }
        var value = metadata
        value.plans = rows(\.plans)
        value.actuals = rows(\.actuals)
        value.recordLinks = rows(\.recordLinks)
        value.memos = rows(\.memos)
        value.stickers = rows(\.stickers)
        value.photos = rows(\.photos)
        value.calendarEvents = rows(\.calendarEvents)
        value.weather = rows(\.weather)
        value.places = rows(\.places)
        value.travel = rows(\.travel)
        value.floorTransitions = rows(\.floorTransitions)
        // Resolve deletion markers and links only after every day's records are present.
        return CloudSnapshotRecoveryEngine.merge(local: value, remote: value)
    }

    static func dates(in snapshot: TaptionDataSnapshot, now: Date, calendar: Calendar) -> Set<Date> {
        var days: Set<Date> = [calendar.startOfDay(for: now)]
        visit(snapshot, now: now) { start, end in
            let start = min(start, now)
            var day = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: end > now ? now : (end > start ? end.addingTimeInterval(-0.000_001) : start))
            while day <= last {
                days.insert(day)
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        return days
    }

    static func make(_ source: TaptionDataSnapshot, days: [Date], now: Date, calendar: Calendar) -> [Date: TaptionDataSnapshot] {
        let source = PlanCloudSnapshotRecoveryPolicy.iCloudSafe(source)
        let orderedDays = days.sorted()
        var empty = TaptionDataSnapshot.empty
        empty.schemaVersion = source.schemaVersion
        empty.updatedAt = source.updatedAt
        empty.categories = source.categories
        empty.settings = source.settings
        empty.yearlyReports = source.yearlyReports
        var result = Dictionary(uniqueKeysWithValues: orderedDays.map { ($0, empty) })

        func append<Value>(_ values: [Value], to field: WritableKeyPath<TaptionDataSnapshot, [Value]>,
                           range: (Value) -> (Date, Date)) {
            for value in values {
                let (recordStart, end) = range(value)
                let start = min(recordStart, now)
                let first = calendar.startOfDay(for: start)
                let last = calendar.startOfDay(for: end > now ? now : (end > start ? end.addingTimeInterval(-0.000_001) : start))
                var lower = 0
                var upper = orderedDays.count
                while lower < upper {
                    let middle = (lower + upper) / 2
                    if orderedDays[middle] < first { lower = middle + 1 } else { upper = middle }
                }
                while lower < orderedDays.count, orderedDays[lower] <= last {
                    result[orderedDays[lower]]![keyPath: field].append(value)
                    lower += 1
                }
            }
        }
        append(source.plans, to: \.plans) { ($0.span.start, $0.span.end) }
        append(source.actuals, to: \.actuals) { ($0.startedAt, $0.endedAt ?? .distantFuture) }
        append(source.recordLinks, to: \.recordLinks) { ($0.createdAt, $0.createdAt) }
        append(source.memos, to: \.memos) { ($0.occurredAt, $0.occurredAt) }
        append(source.stickers, to: \.stickers) { ($0.occurredAt, $0.occurredAt) }
        append(source.photos, to: \.photos) { ($0.capturedAt, $0.capturedAt) }
        append(source.calendarEvents, to: \.calendarEvents) { ($0.span.start, $0.span.end) }
        append(source.weather, to: \.weather) { ($0.observedAt, $0.validUntil ?? $0.observedAt) }
        append(source.places, to: \.places) { ($0.span.start, $0.span.end) }
        append(source.travel, to: \.travel) { ($0.span.start, $0.span.end) }
        append(source.floorTransitions, to: \.floorTransitions) { ($0.span.start, $0.span.end) }
        return result
    }

    private static func visit(_ value: TaptionDataSnapshot, now: Date, body: (Date, Date) -> Void) {
        value.plans.forEach { body($0.span.start, $0.span.end) }
        value.actuals.forEach { body($0.startedAt, $0.endedAt ?? .distantFuture) }
        value.recordLinks.forEach { body($0.createdAt, $0.createdAt) }
        value.memos.forEach { body($0.occurredAt, $0.occurredAt) }
        value.stickers.forEach { body($0.occurredAt, $0.occurredAt) }
        value.photos.forEach { body($0.capturedAt, $0.capturedAt) }
        value.calendarEvents.forEach { body($0.span.start, $0.span.end) }
        value.weather.forEach { body($0.observedAt, $0.validUntil ?? $0.observedAt) }
        value.places.forEach { body($0.span.start, $0.span.end) }
        value.travel.forEach { body($0.span.start, $0.span.end) }
        value.floorTransitions.forEach { body($0.span.start, $0.span.end) }
    }
}
