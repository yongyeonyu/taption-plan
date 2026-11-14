import Foundation

/// AI 확인 목록 2단계(AIQ1111A02). 하루 기록(`/activity`)을 올린 직후 같은 자료에서 앱이 정하지 못한 것을 골라
/// AI 목록에 올린다. AI는 `get_activity`로 그날을 읽고 기존 쓰기 도구(update_activity·merge_records·add_expense)로 고친다.
/// 끝난 지 30분 지난 것만, 하루 5건까지, 같은 것은 한 번만 올린다.
@MainActor
enum AITaskProducer {
    struct Candidate: Equatable {
        var key: String
        var kind: AITaskQueue.Kind
        var text: String
        var context: [String: String]
    }

    static let producedKey = "aiTaskProducedKeys"
    static let perDayLimit = 5
    static let settleDelay: TimeInterval = 30 * 60
    private static let producedLimit = 300
    private static let transitModes: Set<String> = ["subway", "bus"]

    /// 고른 것을 AI 목록에 넣는다. 넣은 것만 기억해, 연결이 없을 때 고른 것은 다음에 다시 본다.
    @discardableResult
    static func enqueue(_ days: [AssistantActivityDay], language: MapHomeLanguage, now: Date,
                        defaults: UserDefaults = .standard) -> Int {
        var produced = defaults.stringArray(forKey: producedKey) ?? []
        let seen = Set(produced)
        var count = 0
        days: for day in days {
            // 목록은 기기 시간대로 날짜를 적으니, 그 날짜의 기기 낮 12시로 넘긴다.
            let date = dayFormatter.date(from: day.date)?.addingTimeInterval(12 * 3_600)
            for candidate in candidates(day, language: language, now: now) where !seen.contains(candidate.key) {
                guard AITaskQueue.enqueue(candidate.kind, text: candidate.text, day: date, context: candidate.context, defaults: defaults)
                else { break days }
                produced.append(candidate.key)
                count += 1
            }
        }
        if produced.count > producedLimit { produced.removeFirst(produced.count - producedLimit) }
        defaults.set(produced, forKey: producedKey)
        return count
    }

    /// 하루에서 확인 거리를 고른다. 순서: 머문 곳 → 교통비 → 조각 합침 → 경로.
    static func candidates(_ day: AssistantActivityDay, language: MapHomeLanguage, now: Date) -> [Candidate] {
        let cutoff = now.addingTimeInterval(-settleDelay)
        let moves = (day.moves ?? []).compactMap { move -> Span<AssistantActivityDay.Move>? in
            span(move, start: move.start, end: move.end)
        }.filter { $0.end <= cutoff }
        let records = day.records.compactMap { span($0, start: $0.start, end: $0.end) }
        func recordIDs(_ start: Date, _ end: Date) -> String {
            records.filter { $0.start < end && $0.end > start }.map(\.value.id).joined(separator: ",")
        }
        func clock(_ start: Date, _ end: Date) -> String { "\(clockFormatter.string(from: start))–\(clockFormatter.string(from: end))" }
        func key(_ kind: AITaskQueue.Kind, _ start: Date) -> String { "\(kind.rawValue)|\(day.date)|\(Int(start.timeIntervalSince1970))" }
        var result: [Candidate] = []

        let unnamed = [language.text("머문 곳", "Place"), "머문 곳", "Place"]
        for visit in (day.visits ?? []).compactMap({ span($0, start: $0.start, end: $0.end) })
        where unnamed.contains(visit.value.place) && visit.value.minutes >= 30 && visit.end <= cutoff {
            result.append(Candidate(
                key: key(.stayPlace, visit.start), kind: .stayPlace,
                text: "\(clock(visit.start, visit.end)) · \(visit.value.place) · \(language.text("\(visit.value.minutes)분", "\(visit.value.minutes) min"))",
                context: ["start": visit.value.start, "end": visit.value.end, "recordIds": recordIDs(visit.start, visit.end)]
            ))
        }

        let expenses = (day.expenses ?? []).filter { $0.category == LedgerCategory.transport.rawValue }.compactMap { parser.date(from: $0.time) }
        for trip in transitTrips(moves) {
            let start = trip.first!.start, end = trip.last!.end
            let paid = expenses.contains { $0 >= start.addingTimeInterval(-settleDelay) && $0 <= end.addingTimeInterval(settleDelay) }
            guard !paid else { continue }
            let modes = trip.map { title($0.value.mode, language) }
            let from = trip.first!.value.from ?? "?", to = trip.last!.value.to ?? "?"
            result.append(Candidate(
                key: key(.fareCheck, start), kind: .fareCheck,
                text: "\(clock(start, end)) · \(from) → \(to) · \(modes.joined(separator: " → "))",
                context: ["start": trip.first!.value.start, "end": trip.last!.value.end, "modes": trip.map(\.value.mode).joined(separator: ","),
                          "from": from, "to": to]
            ))
        }

        for run in fragmentRuns(moves) {
            let start = run.first!.start, end = run.last!.end
            result.append(Candidate(
                key: key(.mergeReview, start), kind: .mergeReview,
                text: "\(clock(start, end)) · \(title(run[0].value.mode, language)) × \(run.count)",
                context: ["start": run.first!.value.start, "end": run.last!.value.end, "mode": run[0].value.mode,
                          "recordIds": recordIDs(start, end)]
            ))
        }

        for move in moves where isUnclear(move.value) {
            result.append(Candidate(
                key: key(.routeCheck, move.start), kind: .routeCheck,
                text: "\(clock(move.start, move.end)) · \(move.value.from ?? "?") → \(move.value.to ?? "?") · \(title(move.value.mode, language))",
                context: ["start": move.value.start, "end": move.value.end, "mode": move.value.mode,
                          "recordIds": recordIDs(move.start, move.end)]
            ))
        }
        return Array(result.prefix(perDayLimit))
    }

    // MARK: 고르는 규칙

    struct Span<Value> {
        var value: Value
        var start: Date
        var end: Date
    }

    /// 지하철·버스 구간을 한 번의 승차로 묶는다. 사이에 걷기만 있고 30분 안이면 환승으로 본다.
    static func transitTrips(_ moves: [Span<AssistantActivityDay.Move>]) -> [[Span<AssistantActivityDay.Move>]] {
        var trips: [[Span<AssistantActivityDay.Move>]] = []
        var current: [Span<AssistantActivityDay.Move>] = []
        var lastTransitEnd: Date?
        for move in moves {
            if transitModes.contains(move.value.mode) {
                guard move.value.minutes >= 3 else { continue }
                if let lastTransitEnd, move.start.timeIntervalSince(lastTransitEnd) <= settleDelay, !current.isEmpty {
                    current.append(move)
                } else {
                    if !current.isEmpty { trips.append(current) }
                    current = [move]
                }
                lastTransitEnd = move.end
            } else if move.value.mode != "walk" {
                if !current.isEmpty { trips.append(current) }
                current = []
                lastTransitEnd = nil
            }
        }
        if !current.isEmpty { trips.append(current) }
        return trips
    }

    /// 같은 수단의 10분 안 조각이 3분 안 틈으로 이어진 묶음(신호 대기·엘리베이터로 쪼개진 이동).
    static func fragmentRuns(_ moves: [Span<AssistantActivityDay.Move>]) -> [[Span<AssistantActivityDay.Move>]] {
        var runs: [[Span<AssistantActivityDay.Move>]] = []
        var current: [Span<AssistantActivityDay.Move>] = []
        for move in moves {
            let short = move.value.minutes < 10
            if short, let last = current.last, last.value.mode == move.value.mode, move.start.timeIntervalSince(last.end) <= 3 * 60 {
                current.append(move)
                continue
            }
            if current.count >= 2 { runs.append(current) }
            current = short ? [move] : []
        }
        if current.count >= 2 { runs.append(current) }
        return runs
    }

    /// 수단이 「기타」로 5분 넘거나, 출발·도착을 모두 모르는 15분 넘는 이동.
    static func isUnclear(_ move: AssistantActivityDay.Move) -> Bool {
        (move.mode == "other" && move.minutes >= 5) || (move.from == nil && move.to == nil && move.minutes >= 15)
    }

    private static func title(_ mode: String, _ language: MapHomeLanguage) -> String {
        TravelMapMode(rawValue: mode)?.title(language) ?? language.text("기타", "Other")
    }

    private static func span<Value>(_ value: Value, start: String, end: String) -> Span<Value>? {
        guard let from = parser.date(from: start), let to = parser.date(from: end), to > from else { return nil }
        return Span(value: value, start: from, end: to)
    }

    private static var parser: DateFormatter { AssistantActivityBuilder.Stamp.instantParser }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// 보이는 시각은 기기 시간대로.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 앨범 영수증 자동 확인 (RPA1114A01)

import Photos
import UIKit

/// 앨범에 새로 들어온 사진의 글자를 기기 안에서 읽어, 영수증으로 보이는 것만 글자를 AI 목록에 올린다.
/// 사진은 기기를 떠나지 않고, 영수증이 아닌 사진의 글자는 올리지 않는다.
/// 스위치는 없다(대표 지시, RPO1114A01): AI가 연결돼 있고 사진 접근이 허락돼 있으면 늘 돈다.
@MainActor
enum ReceiptPhotoScanner {
    static let cursorKey = "receiptPhotoScanCursor"
    /// 처음 돌 때 하루 전 사진부터 본다(방금 찍어 둔 영수증).
    static let lookback: TimeInterval = 86_400
    static let batchLimit = 6
    nonisolated static let receiptWords = ["영수증", "합계", "결제금액", "결제 금액", "받을금액", "승인번호", "승인 번호", "카드번호", "사업자", "부가세", "과세",
                               "거래일시", "가맹점", "RECEIPT", "TOTAL", "SUBTOTAL", "VAT", "CARD NO", "領収", "合計", "小計", "合计", "发票"]
    private static var isRunning = false

    /// 어디부터 볼지. 처음이면 하루 전으로 잡아 적어 둔다.
    static func startCursor(now: Date, defaults: UserDefaults = .standard) -> Date {
        if defaults.object(forKey: cursorKey) == nil { defaults.set(now.addingTimeInterval(-lookback).timeIntervalSince1970, forKey: cursorKey) }
        return Date(timeIntervalSince1970: defaults.double(forKey: cursorKey))
    }

    /// 영수증으로 볼 글: 결제 글 모양이고, 줄이 넉넉하며, 영수증 낱말이 둘 이상.
    nonisolated static func isReceipt(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n")
        guard lines.count >= 4, LedgerMessageParser.looksLikePayment(text) else { return false }
        let upper = text.uppercased()
        return receiptWords.filter { upper.contains($0.uppercased()) }.count >= 2
    }

    /// 영수증에 찍힌 날(연-월-일, 두 자리 연도 포함). 찍은 날보다 뒤이거나 60일 넘게 앞이면 믿지 않고 찍은 날을 쓴다.
    /// 어제 결제한 영수증을 오늘 찍어도 지출은 결제한 날로 들어가게 한다(대표 지시 2026-11-14).
    nonisolated static func receiptDay(_ lines: [String], taken: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let regex = try? NSRegularExpression(pattern: #"(?<![0-9])(20[0-9]{2}|[0-9]{2})\s*[-./년]\s*([0-9]{1,2})\s*[-./월]\s*([0-9]{1,2})(?![0-9])"#)
        for line in lines {
            let text = line as NSString
            guard let match = regex?.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
                  let rawYear = Int(text.substring(with: match.range(at: 1))), let month = Int(text.substring(with: match.range(at: 2))),
                  let day = Int(text.substring(with: match.range(at: 3))), (1...12).contains(month), (1...31).contains(day)
            else { continue }
            let year = rawYear < 100 ? 2000 + rawYear : rawYear
            guard let noon = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else { continue }
            let gap = calendar.startOfDay(for: taken).timeIntervalSince(calendar.startOfDay(for: noon))
            if gap >= 0, gap <= 60 * 86_400 { return gap == 0 ? taken : noon }
        }
        return taken
    }

    /// 영수증에 찍힌 시각(시:분)을 그날에 얹는다. 없으면 nil.
    nonisolated static func receiptMoment(_ lines: [String], day: Date, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let regex = try? NSRegularExpression(pattern: #"(?<![0-9:])([01]?[0-9]|2[0-3]):([0-5][0-9])(?![0-9])"#)
        for line in lines {
            let text = line as NSString
            guard let match = regex?.firstMatch(in: line, range: NSRange(location: 0, length: text.length)),
                  let hour = Int(text.substring(with: match.range(at: 1))), let minute = Int(text.substring(with: match.range(at: 2)))
            else { continue }
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        return nil
    }

    /// 같은 결제로 볼 가계부 기록(대표 지시 2026-11-14: 결제 시간·금액·장소가 같으면 한 건만).
    /// 금액이 같고, 시각이 앞뒤 10분 안(영수증에 시각이 없으면 같은 날)이며, 가게 이름이 겹친다(영수증에서 이름을 못 읽었으면 이름은 보지 않는다).
    nonisolated static func sameSpending(amount: Double, merchant: String?, day: Date, moment: Date?, in entries: [LedgerEntry],
                                         calendar: Calendar = .autoupdatingCurrent) -> LedgerEntry? {
        entries.first { entry in
            guard entry.kind == .expense, abs(entry.amount - amount) < 0.5 else { return false }
            if let moment { guard abs(entry.occurredAt.timeIntervalSince(moment)) <= 600 else { return false } }
            else { guard calendar.isDate(entry.occurredAt, inSameDayAs: day) else { return false } }
            guard let merchant, !merchant.isEmpty else { return moment != nil }
            return namesOverlap(merchant, entry.title) || (entry.place.map { namesOverlap(merchant, $0) } ?? false)
        }
    }

    /// 띄어쓰기·기호를 뺀 이름이 서로를 품거나 앞 두 글자가 같다.
    nonisolated static func namesOverlap(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().filter { $0.isLetter || $0.isNumber }, y = b.lowercased().filter { $0.isLetter || $0.isNumber }
        guard x.count >= 2, y.count >= 2 else { return false }
        return x.contains(y) || y.contains(x) || x.prefix(2) == y.prefix(2)
    }

    /// 읽지 못한 사진을 건너뛸지. 방금 찍은 것은 기기 잠금·저장 중일 수 있어 다음에 다시 본다.
    nonisolated static func skipsUnreadable(created: Date, now: Date) -> Bool { now.timeIntervalSince(created) > 3_600 }

    /// 새 사진을 오래된 것부터 `batchLimit`장까지 본다. AI에게 맡긴 수를 돌려준다.
    @discardableResult
    static func scan(now: Date = .now, deadline: Date? = nil, defaults: UserDefaults = .standard) async -> Int {
        guard !isRunning, MemoPolishQueue.hasConnection(defaults) else { return 0 }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return 0 }
        isRunning = true
        defer { isRunning = false }
        let cursor = startCursor(now: now, defaults: defaults)
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@ AND mediaType == %d", cursor as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.fetchLimit = batchLimit
        await markEarlier(before: cursor, defaults: defaults)
        let found = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        found.enumerateObjects { asset, _, _ in assets.append(asset) }
        var sent = 0, seen = 0
        for asset in assets {
            if let deadline, Date.now >= deadline { break }
            guard let created = asset.creationDate else { continue }
            guard let image = await image(asset) else {
                if skipsUnreadable(created: created, now: now) { defaults.set(created.timeIntervalSince1970, forKey: cursorKey); continue }
                break
            }
            let lines = await LedgerReceiptReader.recognize(image)
            seen += 1
            if isReceipt(lines) {
                ReceiptPhotoMarks.add(asset.localIdentifier, defaults: defaults)
                let day = receiptDay(lines, taken: created)
                var context = ["from": "photo_album"]
                // 결제 문자로 이미 들어간 같은 결제가 있으면 새로 넣지 않고 그 기록을 확인만 하게 한다.
                if let draft = LedgerReceiptReader.draft(lines) {
                    await LedgerBook.shared.load()
                    let match = sameSpending(amount: draft.amount, merchant: draft.merchant, day: day,
                                             moment: receiptMoment(lines, day: day), in: LedgerBook.shared.entries)
                    if let match { context["entryId"] = match.id.uuidString }
                }
                if AITaskQueue.enqueue(.receiptText, text: lines.joined(separator: "\n"), day: day, context: context, defaults: defaults) { sent += 1 }
            }
            defaults.set(created.timeIntervalSince1970, forKey: cursorKey)
        }
        if seen > 0 { TaptionPlanDiagnosticsLogger.shared.record("receipt_photo_scan", fields: ["seen": String(seen), "sent": String(sent)]) }
        return sent
    }

    /// 표시가 생기기 전에 이미 읽은 사진(하루 치)에 한 번만 표시를 채운다. AI에게 다시 보내지 않는다.
    private static func markEarlier(before cursor: Date, defaults: UserDefaults) async {
        guard !defaults.bool(forKey: ReceiptPhotoMarks.backfillKey) else { return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate > %@ AND creationDate <= %@ AND mediaType == %d",
                                        cursor.addingTimeInterval(-lookback) as NSDate, cursor as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 24
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in assets.append(asset) }
        for asset in assets {
            // 기기가 잠겨 못 읽으면 다음에 다시 한다.
            guard let image = await image(asset) else { return }
            if isReceipt(await LedgerReceiptReader.recognize(image)) { ReceiptPhotoMarks.add(asset.localIdentifier, defaults: defaults) }
        }
        defaults.set(true, forKey: ReceiptPhotoMarks.backfillKey)
    }

    /// 기기에 있는 그림만(아이클라우드에서 받지 않는다). 긴 쪽 1,800점.
    private static func image(_ asset: PHAsset) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 1_800, height: 1_800), contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image?.cgImage)
            }
        }
    }
}

/// 앱이 살아 있는 동안(뒤에서 위치를 받는 동안 포함) 앨범이 바뀌면 바로 본다.
@MainActor
final class ReceiptPhotoWatcher: NSObject, PHPhotoLibraryChangeObserver {
    static let shared = ReceiptPhotoWatcher()
    private var isRegistered = false

    private var didAsk = false

    /// 사진 접근이 허락됐을 때만 지켜본다. 여러 번 불러도 한 번만 건다.
    /// 아직 묻지 않은 기기는 AI가 연결돼 있을 때 한 번 묻는다.
    func startIfNeeded() {
        guard !isRegistered else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined, !didAsk, MemoPolishQueue.hasConnection() {
            didAsk = true
            _Concurrency.Task { @MainActor in
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                self.startIfNeeded()
                await ReceiptPhotoScanner.scan()
            }
            return
        }
        guard status == .authorized || status == .limited else { return }
        isRegistered = true
        PHPhotoLibrary.shared().register(self)
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        _Concurrency.Task { @MainActor in await ReceiptPhotoScanner.scan() }
    }
}

/// 글자를 읽어 영수증으로 본 앨범 사진의 표시. 사진 id만 기기에 적는다.
enum ReceiptPhotoMarks {
    static let key = "receiptPhotoMarks"
    static let backfillKey = "receiptPhotoMarksBackfilled"
    static let limit = 400

    static func contains(_ id: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: key)?.contains(id) ?? false
    }

    static func add(_ id: String, defaults: UserDefaults = .standard) {
        var ids = defaults.stringArray(forKey: key) ?? []
        guard !ids.contains(id) else { return }
        ids.append(id)
        defaults.set(Array(ids.suffix(limit)), forKey: key)
    }
}
