import SwiftUI
import TaptionTripShare

// 공지(TSH1114A26 묶음 C).
// - 공지는 방에만 있다(로컬 정본에 넣지 않는다). 방이 사라지면 함께 사라진다.
// - 확인은 `session.acknowledge`, 쓰기는 `session.write([.create(.notice(...))])`. 장소는 이름만 싣고 좌표는 싣지 않는다.
// - 확인해야 하는 사람은 쓴 사람을 뺀 지금의 참여자다. 쓴 사람에게는 확인한 사람과 아직인 사람을 이름으로 보인다.

/// 공지 한 줄에 보일 값.
struct TripShareNoticeRow: Identifiable, Equatable, Sendable {
    let id: String
    var text: String
    var important: Bool
    var author: String
    var isMine: Bool
    var createdAt: Date
    var due: Date?
    var place: String?
    /// 내가 확인해야 하는데 아직 안 했다.
    var needsMyAck: Bool
    /// 확인한 사람·아직인 사람(쓴 사람 빼고, 참여자 번호 순).
    var done: [String]
    var waiting: [String]
}

@MainActor
enum TripShareNotices {
    static let textLimit = 500

    /// 공지 목록(새것부터).
    static func rows(view: ShareRoomView, names: TripShareNames) -> [TripShareNoticeRow] {
        view.items(of: .notice).compactMap { item -> TripShareNoticeRow? in
            guard case .notice(let notice) = item.content else { return nil }
            let readers = view.members.map(\.no).filter { $0 != item.createdBy }.sorted()
            return TripShareNoticeRow(
                id: item.id, text: notice.text, important: notice.important, author: names.name(.member(item.createdBy)), isMine: item.createdBy == view.me,
                createdAt: date(notice.createdAt), due: notice.due.map(date), place: notice.place,
                needsMyAck: item.createdBy != view.me && item.acks[view.me] == nil,
                done: readers.filter { item.acks[$0] != nil }.map { names.name(.member($0)) },
                waiting: readers.filter { item.acks[$0] == nil }.map { names.name(.member($0)) }
            )
        }
        .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    private static func date(_ milliseconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000) }

    /// 공지를 올린다. 글이 비면 올리지 않는다.
    @discardableResult
    static func post(text: String, important: Bool = false, due: Date? = nil, place: String? = nil, tripID: String, now: Date = .now) async -> TripShareLedger.Failure? {
        let body = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(textLimit))
        guard !body.isEmpty else { return .failed }
        guard let room = await TripShareLedger.open(tripID: tripID), room.view.canWrite else { return .viewOnly }
        let spot = place?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notice = ShareNoticeContent(
            text: body, important: important, createdAt: Int((now.timeIntervalSince1970 * 1000).rounded()),
            due: due.map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }, place: spot?.isEmpty == false ? spot.map { String($0.prefix(80)) } : nil, by: room.view.me
        )
        return await run(tripID) { try await room.session.write([.create(.notice(notice))]) == .done }
    }

    /// 공지를 확인했다고 알린다.
    @discardableResult
    static func acknowledge(noticeID: String, tripID: String) async -> TripShareLedger.Failure? {
        guard let room = await TripShareLedger.open(tripID: tripID), room.view.canWrite else { return .viewOnly }
        return await run(tripID) {
            try await room.session.acknowledge(noticeID: noticeID)
            return true
        }
    }

    /// 공지를 지운다(쓴 사람과 주인만).
    @discardableResult
    static func delete(noticeID: String, tripID: String) async -> TripShareLedger.Failure? {
        guard let room = await TripShareLedger.open(tripID: tripID), room.view.canWrite else { return .viewOnly }
        return await run(tripID) { try await room.session.write([.delete(id: noticeID)]) == .done }
    }

    private static func run(_ tripID: String, _ work: () async throws -> Bool) async -> TripShareLedger.Failure? {
        var result: TripShareLedger.Failure?
        do {
            if try await !work() { result = .conflict }
        } catch { result = TripShareLedger.failure(error) }
        await TripShareStore.shared.refresh(tripID: tripID)
        return result
    }
}

/// 여행 머리줄 아래의 확인 안 한 공지 띠.
struct TripShareNoticeBand: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    @State private var isWorking = false

    var body: some View {
        let store = TripShareStore.shared
        if store.isShared(tripID), let view = store.view(tripID: tripID) {
            let waiting = TripShareNoticeAlerts.pending(in: view)
            if let first = waiting.first {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: first.notice.important ? "exclamationmark.bubble.fill" : "megaphone.fill")
                        .foregroundStyle(first.notice.important ? TravelInk.actual : TravelInk.plan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: first.notice.text).font(.caption.weight(.medium)).lineLimit(3)
                        if waiting.count > 1 {
                            Text(language.text("공지 \(waiting.count - 1)개 더", "\(waiting.count - 1) more notices")).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Button(language.text("확인", "OK")) {
                        isWorking = true
                        Task {
                            if let failure = await TripShareNotices.acknowledge(noticeID: first.item.id, tripID: tripID) { store.notice = failure.message(language) }
                            isWorking = false
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .disabled(isWorking || !view.canWrite)
                    .accessibilityIdentifier("tripShareNoticeAck")
                }
                .padding(8)
                .background(TravelInk.panel, in: RoundedRectangle(cornerRadius: TaptionCorner.large))
                .overlay { RoundedRectangle(cornerRadius: TaptionCorner.large).stroke(TravelInk.border, lineWidth: 1) }
                .accessibilityIdentifier("tripShareNoticeBand")
            }
        }
    }
}

/// 공유 판의 공지 구역: 목록·작성·확인한 사람과 아직인 사람.
struct TripShareNoticeList: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let tripID: String

    @State private var text = ""
    @State private var place = ""
    @State private var important = false
    @State private var hasDue = false
    @State private var due = Date.now.addingTimeInterval(3_600)
    @State private var failure: TripShareLedger.Failure?
    @State private var isWorking = false

    var body: some View {
        let store = TripShareStore.shared
        if store.isShared(tripID), let view = store.view(tripID: tripID), let names = store.names(tripID: tripID) {
            let rows = TripShareNotices.rows(view: view, names: names)
            Section {
                TextField(language.text("일행에게 알릴 말", "Tell the group"), text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("tripShareNoticeText")
                TextField(language.text("장소 이름 (선택)", "Place name (optional)"), text: $place)
                Toggle(language.text("중요", "Important"), isOn: $important)
                Toggle(language.text("시각 넣기", "Add a time"), isOn: $hasDue)
                if hasDue { DatePicker(language.text("언제까지", "By when"), selection: $due) }
                Button(language.text("공지 올리기", "Post notice")) { post() }
                    .disabled(isWorking || !view.canWrite || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("tripShareNoticePost")
            } header: {
                Text(language.text("공지", "Notices"))
            } footer: {
                Text(language.text("앱을 열어 둔 일행에게 바로 보이고, 닫아 둔 일행은 다음에 앱을 열 때 받아요.", "People with the app open see it right away; others get it the next time they open the app."))
            }
            .alert(failure?.message(language) ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(language.text("확인", "OK")) { failure = nil }
            }
            if !rows.isEmpty {
                Section {
                    ForEach(rows) { row in
                        noticeRow(row, canWrite: view.canWrite)
                            .swipeActions {
                                if row.isMine || view.isOwner {
                                    Button(language.text("지우기", "Delete"), role: .destructive) {
                                        Task { failure = await TripShareNotices.delete(noticeID: row.id, tripID: tripID) }
                                    }
                                }
                            }
                    }
                }
            }
        }
    }

    private func post() {
        isWorking = true
        let draft = (text: text, important: important, due: hasDue ? due : nil, place: place)
        Task {
            failure = await TripShareNotices.post(text: draft.text, important: draft.important, due: draft.due, place: draft.place, tripID: tripID)
            if failure == nil {
                text = ""
                place = ""
                important = false
                hasDue = false
            }
            isWorking = false
        }
    }

    @ViewBuilder
    private func noticeRow(_ row: TripShareNoticeRow, canWrite: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                if row.important { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                Text(verbatim: row.text)
            }
            Text(verbatim: detail(row)).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            let total = row.done.count + row.waiting.count
            if total > 0 {
                Text(language.text("확인 \(row.done.count)/\(total)", "Seen \(row.done.count)/\(total)")).font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
            if row.isMine, !row.waiting.isEmpty {
                Text(language.text("아직: \(row.waiting.joined(separator: ", "))", "Not yet: \(row.waiting.joined(separator: ", "))"))
                    .font(.taptionStyle(.caption)).foregroundStyle(.secondary)
            }
            if row.needsMyAck {
                Button(language.text("확인", "OK")) {
                    Task { failure = await TripShareNotices.acknowledge(noticeID: row.id, tripID: tripID) }
                }
                .buttonStyle(.bordered)
                .disabled(!canWrite)
            }
        }
    }

    private func detail(_ row: TripShareNoticeRow) -> String {
        var parts = [row.author, row.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let place = row.place { parts.append(place) }
        if let due = row.due { parts.append(language.text("\(due.formatted(date: .omitted, time: .shortened))까지", "by \(due.formatted(date: .omitted, time: .shortened))")) }
        return parts.joined(separator: " · ")
    }
}
