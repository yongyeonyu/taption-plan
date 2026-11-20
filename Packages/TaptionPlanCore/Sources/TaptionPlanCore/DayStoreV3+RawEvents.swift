import CSQLite
import CryptoKit
import Foundation

extension TaptionPlanV3Store {
    public func validateRawEventsForAppend(
        _ events: [TaptionPlanRawEvent]
    ) throws {
        try validate(events)
        guard !events.isEmpty else { return }
        var candidates: [TaptionPlanRawEventIdentifier: TaptionPlanRawEvent] = [:]
        for event in events {
            let identifier = TaptionPlanRawEventIdentifier(
                domain: event.domain,
                id: event.id
            )
            if let existing = candidates[identifier],
               existing != event {
                throw TaptionPlanV3StoreError.payloadConflict(
                    device: event.device,
                    domain: event.domain,
                    id: event.id
                )
            }
            candidates[identifier] = event
        }
        let lookup = try prepare(
            """
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND domain = ? AND id = ?;
            """
        )
        defer { sqlite3_finalize(lookup) }
        for event in candidates.values {
            try reset(lookup)
            try bind(event.device.rawValue, to: lookup, at: 1)
            try bind(event.domain, to: lookup, at: 2)
            try bind(event.id, to: lookup, at: 3)
            guard try step(lookup) == SQLITE_ROW else { continue }
            guard try readRawEvent(lookup) == event else {
                throw TaptionPlanV3StoreError.payloadConflict(
                    device: event.device,
                    domain: event.domain,
                    id: event.id
                )
            }
        }
    }

    public func replaceRawEvents(
        _ events: [TaptionPlanRawEvent],
        for day: TaptionPlanDayKey,
        domains: Set<String>
    ) throws {
        _ = try replaceRawEvents(
            events,
            for: day,
            exactDomains: domains.map { Data($0.utf8) },
            onlyIfCurrent: nil
        )
    }

    public func replaceRawEvents(
        _ events: [TaptionPlanRawEvent],
        for day: TaptionPlanDayKey,
        exactDomains: [String]
    ) throws {
        _ = try replaceRawEvents(
            events,
            for: day,
            exactDomains: exactDomains.map { Data($0.utf8) },
            onlyIfCurrent: nil
        )
    }

    @discardableResult
    public func replaceRawEvents(
        _ events: [TaptionPlanRawEvent],
        for day: TaptionPlanDayKey,
        domains: Set<String>,
        onlyIfCurrent expectedCurrentEvents: [TaptionPlanRawEvent]
    ) throws -> Bool {
        try replaceRawEvents(
            events,
            for: day,
            exactDomains: domains.map { Data($0.utf8) },
            onlyIfCurrent: Optional(expectedCurrentEvents)
        )
    }

    @discardableResult
    public func replaceRawEvents(
        _ events: [TaptionPlanRawEvent],
        for day: TaptionPlanDayKey,
        exactDomains: [String],
        onlyIfCurrent expectedCurrentEvents: [TaptionPlanRawEvent]
    ) throws -> Bool {
        try replaceRawEvents(
            events,
            for: day,
            exactDomains: exactDomains.map { Data($0.utf8) },
            onlyIfCurrent: Optional(expectedCurrentEvents)
        )
    }

    private func replaceRawEvents(
        _ events: [TaptionPlanRawEvent],
        for day: TaptionPlanDayKey,
        exactDomains: [Data],
        onlyIfCurrent expectedCurrentEvents: [TaptionPlanRawEvent]?
    ) throws -> Bool {
        try validate(day: day)
        let domains = Set(exactDomains)
        guard !domains.isEmpty,
              domains.allSatisfy({ !$0.isEmpty && !$0.contains(0) }) else {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        try validate(events)
        guard events.allSatisfy({ event in
            event.day == day && domains.contains(Data(event.domain.utf8))
        })
        else {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        if let expectedCurrentEvents {
            try validate(expectedCurrentEvents)
            guard expectedCurrentEvents.allSatisfy({ event in
                event.day == day && domains.contains(Data(event.domain.utf8))
            }) else {
                throw TaptionPlanV3StoreError.invalidDomain
            }
        }
        guard let database else { throw lastError() }
        let changeCount = sqlite3_total_changes(database)
        let delete = try prepare(
            "DELETE FROM raw_events WHERE device = ? AND day_key = ? AND domain = ?;"
        )
        defer { sqlite3_finalize(delete) }
        var didReplace = false
        try withTransaction {
            if let expectedCurrentEvents {
                let currentEvents = try rawEvents(for: day).filter { event in
                    domains.contains(Data(event.domain.utf8))
                }
                guard Set(currentEvents) == Set(expectedCurrentEvents) else {
                    return
                }
            }
            try removePersistedRawDigests(for: Set([day]))
            let storedDomains = try rawDomains(for: day).map { Data($0.utf8) }.filter { domain in
                domains.contains(domain)
            }
            for domain in Array(domains) + storedDomains {
                try reset(delete)
                try bind(device.rawValue, to: delete, at: 1)
                try bind(Self.dayKey(day), to: delete, at: 2)
                try bindText(domain, to: delete, at: 3)
                guard try step(delete) == SQLITE_DONE else { throw lastError() }
            }
            _ = try insertRawEvents(events)
            didReplace = true
        }
        if didReplace { rawEventRevision &+= 1 }
        if didReplace && sqlite3_total_changes(database) != changeCount {
            removeCachedRawDigest(for: day)
        }
        return didReplace
    }

    func validate(_ events: [TaptionPlanRawEvent]) throws {
        guard events.allSatisfy({ $0.device == device }) else {
            throw TaptionPlanV3StoreError.invalidDevice
        }
        guard events.allSatisfy(\.day.isValidStorageKey) else {
            throw TaptionPlanV3StoreError.invalidDay
        }
        guard events.allSatisfy({ !$0.domain.isEmpty && !containsNUL($0.domain) }) else {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        guard events.allSatisfy({ !$0.id.isEmpty && !containsNUL($0.id) }) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
    }

    func validate(_ items: [TaptionPlanV3OutboxItem]) throws {
        guard items.allSatisfy({ !$0.id.isEmpty && !containsNUL($0.id) }) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        guard items.allSatisfy({ !$0.kind.isEmpty && !containsNUL($0.kind) }) else {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        guard items.allSatisfy({ !$0.payload.isEmpty }) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        guard items.allSatisfy({ $0.payload.count <= 4 * 1_024 * 1_024 }) else {
            throw TaptionPlanV3StoreError.outboxPayloadTooLarge(
                limit: 4 * 1_024 * 1_024
            )
        }
    }

    func validate(day: TaptionPlanDayKey) throws {
        guard day.isValidStorageKey else {
            throw TaptionPlanV3StoreError.invalidDay
        }
    }

    func insertOutboxItems(
        _ items: [TaptionPlanV3OutboxItem]
    ) throws {
        guard !items.isEmpty else { return }
        let insert = try prepare(
            """
            INSERT OR IGNORE INTO device_outbox(device, id, kind, payload)
            VALUES (?, ?, ?, ?);
            """
        )
        let lookup = try prepare(
            """
            SELECT kind, payload FROM device_outbox
            WHERE device = ? AND id = ?;
            """
        )
        defer {
            sqlite3_finalize(insert)
            sqlite3_finalize(lookup)
        }
        for item in items {
            try reset(insert)
            try bind(device.rawValue, to: insert, at: 1)
            try bind(item.id, to: insert, at: 2)
            try bind(item.kind, to: insert, at: 3)
            try bind(item.payload, to: insert, at: 4)
            guard try step(insert) == SQLITE_DONE else { throw lastError() }
            guard sqlite3_changes(database) == 0 else { continue }

            try reset(lookup)
            try bind(device.rawValue, to: lookup, at: 1)
            try bind(item.id, to: lookup, at: 2)
            guard try step(lookup) == SQLITE_ROW,
                  let kind = sqlite3_column_text(lookup, 0).map({
                      String(cString: $0)
                  }) else {
                throw lastError()
            }
            guard exactlyEqual(kind, item.kind),
                  readData(lookup, at: 1) == item.payload else {
                throw TaptionPlanV3StoreError.outboxConflict(id: item.id)
            }
        }
        let count = try prepare(
            "SELECT COUNT(*), COALESCE(SUM(length(payload)), 0) FROM device_outbox WHERE device = ?;"
        )
        defer { sqlite3_finalize(count) }
        try bind(device.rawValue, to: count, at: 1)
        guard try step(count) == SQLITE_ROW else { throw lastError() }
        if sqlite3_column_int64(count, 0) > 4_096 {
            throw TaptionPlanV3StoreError.outboxLimitExceeded(limit: 4_096)
        }
        if sqlite3_column_int64(count, 1) > 64 * 1_024 * 1_024 {
            throw TaptionPlanV3StoreError.outboxByteLimitExceeded(
                limit: 64 * 1_024 * 1_024
            )
        }
    }

    public func deleteRawEvents(
        ids: [String],
        domain: String
    ) throws {
        guard !domain.isEmpty, !containsNUL(domain) else {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        guard ids.allSatisfy({ !$0.isEmpty && !containsNUL($0) }) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        guard !ids.isEmpty else { return }
        guard let database else { throw lastError() }
        let lookup = try prepare(
            "SELECT day_key FROM raw_events WHERE device = ? AND domain = ? AND id = ?;"
        )
        let delete = try prepare(
            "DELETE FROM raw_events WHERE device = ? AND domain = ? AND id = ?;"
        )
        defer {
            sqlite3_finalize(lookup)
            sqlite3_finalize(delete)
        }
        var days = Set<TaptionPlanDayKey>()
        var deletedAny = false
        try withTransaction {
            for id in ids {
                try reset(lookup)
                try bind(device.rawValue, to: lookup, at: 1)
                try bind(domain, to: lookup, at: 2)
                try bind(id, to: lookup, at: 3)
                if try step(lookup) == SQLITE_ROW,
                   let value = sqlite3_column_text(lookup, 0).map({
                       String(cString: $0)
                   }), let day = parseDayKey(value) {
                    days.insert(day)
                }
            }
            try removePersistedRawDigests(for: days)
            for id in ids {
                try reset(delete)
                try bind(device.rawValue, to: delete, at: 1)
                try bind(domain, to: delete, at: 2)
                try bind(id, to: delete, at: 3)
                guard try step(delete) == SQLITE_DONE else { throw lastError() }
                if sqlite3_changes(database) > 0 { deletedAny = true }
            }
        }
        if deletedAny { rawEventRevision &+= 1 }
        for day in days {
            removeCachedRawDigest(for: day)
        }
    }

    @discardableResult
    public func removeRawEventsIfUnchanged(
        _ events: [TaptionPlanRawEvent]
    ) throws -> Set<TaptionPlanRawEventIdentifier> {
        try validate(events)
        guard !events.isEmpty else { return [] }
        let lookup = try prepare(
            """
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND domain = ? AND id = ?;
            """
        )
        let delete = try prepare(
            "DELETE FROM raw_events WHERE device = ? AND domain = ? AND id = ?;"
        )
        defer {
            sqlite3_finalize(lookup)
            sqlite3_finalize(delete)
        }
        var removed = Set<TaptionPlanRawEventIdentifier>()
        var days = Set<TaptionPlanDayKey>()
        try withTransaction {
            for expected in events {
                try reset(lookup)
                try bind(device.rawValue, to: lookup, at: 1)
                try bind(expected.domain, to: lookup, at: 2)
                try bind(expected.id, to: lookup, at: 3)
                guard try step(lookup) == SQLITE_ROW,
                      try readRawEvent(lookup) == expected else { continue }

                try reset(delete)
                try bind(device.rawValue, to: delete, at: 1)
                try bind(expected.domain, to: delete, at: 2)
                try bind(expected.id, to: delete, at: 3)
                guard try step(delete) == SQLITE_DONE else { throw lastError() }
                guard sqlite3_changes(database) == 1 else { continue }
                removed.insert(.init(domain: expected.domain, id: expected.id))
                days.insert(expected.day)
            }
            try removePersistedRawDigests(for: days)
        }
        if !removed.isEmpty { rawEventRevision &+= 1 }
        for day in days {
            removeCachedRawDigest(for: day)
        }
        return removed
    }

    func insertRawEvents(
        _ events: [TaptionPlanRawEvent]
    ) throws -> Set<TaptionPlanRawEventIdentifier> {
        let insert = try prepare(
            """
            INSERT OR IGNORE INTO raw_events(
                device, day_key, timestamp, sequence, id, domain,
                provenance, payload
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        let conflictLookup = try prepare(
            """
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND domain = ? AND id = ?;
            """
        )
        defer {
            sqlite3_finalize(insert)
            sqlite3_finalize(conflictLookup)
        }
        var insertedIDs = Set<TaptionPlanRawEventIdentifier>()
        for event in events {
            try reset(insert)
            try bind(event.device.rawValue, to: insert, at: 1)
            try bind(Self.dayKey(event.day), to: insert, at: 2)
            try bind(event.timestamp.timeIntervalSince1970, to: insert, at: 3)
            try bind(event.sequence, to: insert, at: 4)
            try bind(event.id, to: insert, at: 5)
            try bind(event.domain, to: insert, at: 6)
            try bind(try encodeProvenance(event.provenance), to: insert, at: 7)
            try bind(event.payload, to: insert, at: 8)
            guard try step(insert) == SQLITE_DONE else { throw lastError() }
            guard sqlite3_changes(database) == 0 else {
                insertedIDs.insert(.init(domain: event.domain, id: event.id))
                continue
            }

            try reset(conflictLookup)
            try bind(event.device.rawValue, to: conflictLookup, at: 1)
            try bind(event.domain, to: conflictLookup, at: 2)
            try bind(event.id, to: conflictLookup, at: 3)
            guard try step(conflictLookup) == SQLITE_ROW else {
                throw lastError()
            }
            let existing = try readRawEvent(conflictLookup)
            guard existing == event else {
                throw TaptionPlanV3StoreError.payloadConflict(
                    device: event.device,
                    domain: event.domain,
                    id: event.id
                )
            }
        }
        return insertedIDs
    }

    public func rawEvents(
        for day: TaptionPlanDayKey,
        domain: String? = nil
    ) throws -> [TaptionPlanRawEvent] {
        try validate(day: day)
        if let domain, domain.isEmpty || containsNUL(domain) {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        let statement: OpaquePointer
        if domain == nil {
            statement = try prepare(
                """
                SELECT device, day_key, timestamp, sequence, id, domain,
                       provenance, payload
                FROM raw_events
                WHERE device = ? AND day_key = ?
                ORDER BY day_key, timestamp, sequence, id;
                """
            )
        } else {
            statement = try prepare(
                """
                SELECT device, day_key, timestamp, sequence, id, domain,
                       provenance, payload
                FROM raw_events
                WHERE device = ? AND day_key = ? AND domain = ?
                ORDER BY day_key, timestamp, sequence, id;
                """
            )
        }
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        if let domain {
            try bind(domain, to: statement, at: 3)
        }
        var result: [TaptionPlanRawEvent] = []
        while try step(statement) == SQLITE_ROW {
            result.append(try readRawEvent(statement))
        }
        return result
    }

    /// Returns the newest raw event whose identifier begins with a printable-ASCII prefix.
    public func latestRawEvent(
        domain: String,
        idPrefix: String
    ) throws -> TaptionPlanRawEvent? {
        let prefixBytes = Array(idPrefix.utf8)
        guard !idPrefix.isEmpty,
              prefixBytes.allSatisfy({ (0x20...0x7e).contains($0) }),
              let lastByte = prefixBytes.last,
              lastByte < 0x7f else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        guard !domain.isEmpty, !containsNUL(domain) else {
            throw TaptionPlanV3StoreError.invalidDomain
        }

        var upperBoundBytes = prefixBytes
        upperBoundBytes[upperBoundBytes.count - 1] += 1
        let upperBound = String(decoding: upperBoundBytes, as: UTF8.self)
        let statement = try prepare(
            """
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND domain = ?
              AND id COLLATE BINARY >= ? AND id COLLATE BINARY < ?
            ORDER BY sequence DESC, length(id) DESC, id COLLATE BINARY DESC
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(domain, to: statement, at: 2)
        try bind(idPrefix, to: statement, at: 3)
        try bind(upperBound, to: statement, at: 4)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try readRawEvent(statement)
    }

    /// Returns a byte-bounded page; returned cursors expire after any database write.
    public func rawEventPage(
        after cursor: TaptionPlanRawEventCursor? = nil,
        domain: String? = nil,
        limit: Int = 256,
        byteLimit: Int = TaptionPlanV3Store.defaultRawEventPageBytes
    ) throws -> TaptionPlanRawEventPage {
        if let domain, domain.isEmpty || containsNUL(domain) {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        if let cursor,
           cursor.id.isEmpty || cursor.domain.isEmpty
            || containsNUL(cursor.id) || containsNUL(cursor.domain) {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        if let cursor { try validate(day: cursor.day) }
        if let cursor, cursor.sequence > UInt64(Int64.max) {
            throw TaptionPlanV3StoreError.integerOverflow
        }
        if let domain, let cursor,
           !exactlyEqual(domain, cursor.domain) {
            throw TaptionPlanV3StoreError.invalidDomain
        }

        let pageSize = min(max(limit, 1), Self.maximumRawEventPageSize)
        let pageByteLimit = min(
            max(byteLimit, 1),
            Self.maximumRawEventPageBytes
        )
        let cursorClause: String
        let orderClause: String
        if domain != nil {
            cursorClause = cursor == nil
                ? ""
                : "AND (day_key, timestamp, sequence, id) > (?, ?, ?, ?)"
            orderClause = "day_key, timestamp, sequence, id"
        } else {
            cursorClause = cursor == nil
                ? ""
                : "AND (day_key, timestamp, sequence, id, domain) > (?, ?, ?, ?, ?)"
            orderClause = "day_key, timestamp, sequence, id, domain"
        }
        let domainClause = domain == nil ? "" : "AND domain = ?"
        let filterClause = "device = ? \(domainClause) \(cursorClause)"
        func bindFilters(to statement: OpaquePointer) throws -> Int32 {
            var index: Int32 = 1
            try bind(device.rawValue, to: statement, at: index)
            index += 1
            if let domain {
                try bind(domain, to: statement, at: index)
                index += 1
            }
            if let cursor {
                try bind(Self.dayKey(cursor.day), to: statement, at: index)
                index += 1
                try bind(
                    cursor.timestamp.timeIntervalSince1970,
                    to: statement,
                    at: index
                )
                index += 1
                try bind(Int64(bitPattern: cursor.sequence), to: statement, at: index)
                index += 1
                try bind(cursor.id, to: statement, at: index)
                index += 1
                if domain == nil {
                    try bind(cursor.domain, to: statement, at: index)
                    index += 1
                }
            }
            return index
        }

        let scanState = try currentRawEventPageScanState()
        if let cursorState = cursor?.scanState, cursorState != scanState {
            throw TaptionPlanV3StoreError.staleRawEventCursor
        }

        let result = try withReadTransaction {
            let sizeExpression = """
                length(CAST(device AS BLOB))
                + length(CAST(day_key AS BLOB))
                + length(CAST(id AS BLOB))
                + length(CAST(domain AS BLOB))
                + length(provenance) + length(payload) + 64
                """
            let sizeStatement = try prepare(
                """
                SELECT \(sizeExpression)
                FROM raw_events
                WHERE \(filterClause)
                ORDER BY \(orderClause)
                LIMIT ?;
                """
            )
            var eventByteSizes: [Int] = []
            do {
                defer { sqlite3_finalize(sizeStatement) }
                let limitIndex = try bindFilters(to: sizeStatement)
                try bind(Int64(pageSize + 1), to: sizeStatement, at: limitIndex)
                while try step(sizeStatement) == SQLITE_ROW {
                    let value = sqlite3_column_int64(sizeStatement, 0)
                    guard value >= 0, let size = Int(exactly: value) else {
                        throw TaptionPlanV3StoreError.integerOverflow
                    }
                    eventByteSizes.append(size)
                }
            }

            var pageBytes = 0
            var eventCount = 0
            for eventBytes in eventByteSizes.prefix(pageSize) {
                guard eventBytes <= pageByteLimit else {
                    if eventCount == 0 {
                        throw TaptionPlanV3StoreError.rawEventPageItemTooLarge(
                            limit: pageByteLimit
                        )
                    }
                    break
                }
                guard eventBytes <= pageByteLimit - pageBytes else { break }
                pageBytes += eventBytes
                eventCount += 1
            }
            let hasMore = eventByteSizes.count > eventCount

            var events: [TaptionPlanRawEvent] = []
            events.reserveCapacity(eventCount)
            if eventCount > 0 {
                let eventStatement = try prepare(
                    """
                    SELECT device, day_key, timestamp, sequence, id, domain,
                           provenance, payload
                    FROM raw_events
                    WHERE \(filterClause)
                    ORDER BY \(orderClause)
                    LIMIT ?;
                    """
                )
                do {
                    defer { sqlite3_finalize(eventStatement) }
                    let limitIndex = try bindFilters(to: eventStatement)
                    try bind(Int64(eventCount), to: eventStatement, at: limitIndex)
                    while try step(eventStatement) == SQLITE_ROW {
                        events.append(try readRawEvent(eventStatement))
                    }
                }
                guard events.count == eventCount else {
                    throw TaptionPlanV3StoreError.staleRawEventCursor
                }
            }
            return (events, hasMore)
        }
        guard try currentRawEventPageScanState() == scanState else {
            throw TaptionPlanV3StoreError.staleRawEventCursor
        }
        return TaptionPlanRawEventPage(
            events: result.0,
            nextCursor: result.0.last.map {
                TaptionPlanRawEventCursor(after: $0, scanState: scanState)
            },
            hasMore: result.1
        )
    }

    private func rawDomains(for day: TaptionPlanDayKey) throws -> [String] {
        let statement = try prepare(
            "SELECT DISTINCT domain FROM raw_events WHERE device = ? AND day_key = ?;"
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(Self.dayKey(day), to: statement, at: 2)
        var result: [String] = []
        while try step(statement) == SQLITE_ROW {
            guard let value = sqlite3_column_text(statement, 0) else {
                throw TaptionPlanV3StoreError.databaseCorrupt(
                    message: "Invalid raw event domain"
                )
            }
            let bytes = UnsafeBufferPointer(
                start: value,
                count: Int(sqlite3_column_bytes(statement, 0))
            )
            let domain = String(decoding: bytes, as: UTF8.self)
            guard !domain.isEmpty, !containsNUL(domain) else {
                throw TaptionPlanV3StoreError.databaseCorrupt(
                    message: "Invalid raw event domain"
                )
            }
            result.append(domain)
        }
        return result
    }

    public func rawEvent(
        domain: String,
        id: String
    ) throws -> TaptionPlanRawEvent? {
        guard !domain.isEmpty, !containsNUL(domain) else {
            throw TaptionPlanV3StoreError.invalidDomain
        }
        guard !id.isEmpty, !containsNUL(id) else {
            throw TaptionPlanV3StoreError.invalidIdentifier
        }
        let statement = try prepare(
            """
            SELECT device, day_key, timestamp, sequence, id, domain,
                   provenance, payload
            FROM raw_events
            WHERE device = ? AND domain = ? AND id = ?;
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(device.rawValue, to: statement, at: 1)
        try bind(domain, to: statement, at: 2)
        try bind(id, to: statement, at: 3)
        guard try step(statement) == SQLITE_ROW else { return nil }
        return try readRawEvent(statement)
    }

    public func rawDigest(for day: TaptionPlanDayKey) throws -> TaptionPlanDayDigest {
        try validate(day: day)
        let dataVersion = try currentDataVersion()
        if let digest = cachedRawDigest(for: day, dataVersion: dataVersion) {
            return digest
        }
        if let digest = try persistedRawDigest(for: day) {
            cacheRawDigest(digest, for: day, dataVersion: dataVersion)
            return digest
        }
        let dayKey = Self.dayKey(day)
        // D2: 한 줄씩 훑는 동안 다른 연결이 쓰면 앞뒤가 섞인 다이제스트가 된다. 읽기 트랜잭션 하나(같은 스냅샷) 안에서 계산한다.
        let digest = try withReadTransaction { () throws -> TaptionPlanDayDigest in
            let statement = try prepare(
                """
                SELECT timestamp, sequence, id, domain, provenance, payload
                FROM raw_events
                WHERE device = ? AND day_key = ?
                ORDER BY timestamp, sequence, id, domain;
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(device.rawValue, to: statement, at: 1)
            try bind(dayKey, to: statement, at: 2)

            var hasher = SHA256()
            var eventCount = 0
            var firstTimestamp: Date?
            var lastTimestamp: Date?
            while try step(statement) == SQLITE_ROW {
                let timestamp = Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 0)
                )
                let sequence = try readUInt64(sqlite3_column_int64(statement, 1))
                guard let id = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
                      !id.isEmpty,
                      let domain = sqlite3_column_text(statement, 3).map({ String(cString: $0) }),
                      !domain.isEmpty else {
                    throw TaptionPlanV3StoreError.databaseCorrupt(
                        message: "Invalid raw event digest row"
                    )
                }
                let provenance = try decodeProvenance(readData(statement, at: 4))
                Self.appendCanonical(device.rawValue, to: &hasher)
                Self.appendCanonical(dayKey, to: &hasher)
                Self.appendCanonical(timestamp.timeIntervalSince1970, to: &hasher)
                Self.appendCanonical(sequence, to: &hasher)
                Self.appendCanonical(id, to: &hasher)
                Self.appendCanonical(domain, to: &hasher)
                Self.appendCanonical(provenance, to: &hasher)
                try Self.appendCanonicalBlob(statement, at: 5, to: &hasher)
                eventCount += 1
                firstTimestamp = firstTimestamp ?? timestamp
                lastTimestamp = timestamp
            }
            try reset(statement)
            return TaptionPlanDayDigest(
                device: device,
                day: day,
                eventCount: eventCount,
                firstTimestamp: firstTimestamp,
                lastTimestamp: lastTimestamp,
                sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
            )
        }
        let didPersist = try withTransaction {
            guard try currentDataVersion() == dataVersion else { return false }
            try persistRawDigest(digest)
            return true
        }
        if didPersist {
            cacheRawDigest(digest, for: day, dataVersion: dataVersion)
        }
        return digest
    }

    /// Computes the same canonical digest used by the SQLite reader. Migration
    /// code uses this to compare the source event set before and after import.
    public static func digest(
        events: [TaptionPlanRawEvent],
        device: TaptionPlanStoreDevice,
        day: TaptionPlanDayKey
    ) -> TaptionPlanDayDigest {
        let ordered = events.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            if !exactlyEqual($0.id, $1.id) {
                return exactBytesPrecede($0.id, $1.id)
            }
            if !exactlyEqual($0.domain, $1.domain) {
                return exactBytesPrecede($0.domain, $1.domain)
            }
            return false
        }
        var hasher = SHA256()
        for event in ordered {
            appendCanonical(event.device.rawValue, to: &hasher)
            appendCanonical(Self.dayKey(event.day), to: &hasher)
            appendCanonical(event.timestamp.timeIntervalSince1970, to: &hasher)
            appendCanonical(event.sequence, to: &hasher)
            appendCanonical(event.id, to: &hasher)
            appendCanonical(event.domain, to: &hasher)
            appendCanonical(event.provenance, to: &hasher)
            appendCanonical(event.payload, to: &hasher)
        }
        return TaptionPlanDayDigest(
            device: device,
            day: day,
            eventCount: ordered.count,
            firstTimestamp: ordered.first?.timestamp,
            lastTimestamp: ordered.last?.timestamp,
            sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }
}
