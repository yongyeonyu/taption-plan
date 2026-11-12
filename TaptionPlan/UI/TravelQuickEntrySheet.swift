import SwiftUI
import TaptionPlanStore

/// 여행 일정을 손으로 빠르게 넣는 시트(TVQ1112A01). 한 화면에서 분류·시각·길이·이름을 정하고, 넣은 뒤에도 열려 다음 일정으로 이어진다.
struct TravelQuickEntrySheet: View {
    struct Target: Identifiable {
        let id = UUID()
        var tripID: String
        /// 일정이 놓일 날(`YYYY-MM-DD`, 그곳 날짜).
        var dayKey: String
        var dayLabel: String
        var startMinute: Int
        var kind: TripImportItem.Kind
        var offsetSeconds: Int
        /// 고칠 일정. 없으면 새로 넣는다.
        var editing: TravelTripItem?
        /// 장소를 찾을 때 먼저 볼 여행지 가운데(경도, 위도)와, 고칠 일정에 이미 붙은 장소.
        var anchor: SIMD2<Double>?
        var place: TravelItemPlace?

        /// 새 일정: 그 여행의 시간대(없으면 기기 시간대)로 그날에 놓는다.
        static func new(trip: TravelTrip, dayKey: String, dayLabel: String, startMinute: Int, kind: TripImportItem.Kind) -> Target {
            let zone = trip.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            let noon = TravelQuickEntrySheet.date(dayKey: dayKey, minute: 720, offsetSeconds: zone.secondsFromGMT())
            return Target(tripID: trip.id, dayKey: dayKey, dayLabel: dayLabel, startMinute: startMinute, kind: kind, offsetSeconds: zone.secondsFromGMT(for: noon))
        }

        /// 있던 일정 고치기: 그 일정이 적힌 시차 그대로 본다.
        static func edit(_ item: TravelTripItem, dayLabel: String) -> Target {
            let local = Int(item.start.timeIntervalSince1970) + item.startOffsetSeconds
            return Target(
                tripID: item.tripID, dayKey: TravelTripDay.string(for: item.start, offsetSeconds: item.startOffsetSeconds), dayLabel: dayLabel,
                startMinute: ((local % 86_400) + 86_400) % 86_400 / 60, kind: TripImportItem.Kind(rawValue: item.kind) ?? .other,
                offsetSeconds: item.startOffsetSeconds, editing: item
            )
        }
    }

    /// 칩 순서: 계획표 열 순서(이동·식사·관광·숙소) 다음에 자주 쓰는 것.
    static let kinds: [TripImportItem.Kind] = [.transfer, .meal, .sight, .lodging, .cafe, .shopping, .activity, .photo, .rest, .flight, .sleep, .other]

    /// 그날 0시에서 `minute`분 뒤의 절대 시각.
    static func date(dayKey: String, minute: Int, offsetSeconds: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds) ?? .gmt
        let midnight = TravelTripDay.components(dayKey).flatMap(calendar.date(from:)) ?? .now
        return midnight.addingTimeInterval(TimeInterval(minute * 60))
    }

    static func clock(_ minute: Int) -> String {
        let wrapped = ((minute % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
    }

    static func durationText(_ minutes: Int, language: MapHomeLanguage) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return language.runtimeText("\(rest)분", "\(rest)m") }
        if rest == 0 { return language.runtimeText("\(hours)시간", "\(hours)h") }
        return language.runtimeText("\(hours)시간 \(rest)분", "\(hours)h \(rest)m")
    }

    @Bindable var model: AppModel
    let language: MapHomeLanguage
    let target: Target

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFocused: Bool
    @State private var text = ""
    @State private var kind = TripImportItem.Kind.sight
    @State private var startMinute = 540
    @State private var duration = 60
    /// 길이를 직접 골랐으면 분류를 바꿔도 그대로 둔다.
    @State private var isDurationChosen = false
    @State private var parsed = TravelQuickEntry.Parsed(title: "")
    @State private var added: (itemID: String, summary: String)?
    @State private var isSaving = false
    @State private var didFail = false
    @State private var isConfirmingDelete = false
    /// 붙인 장소(지도 핀). 넣은 뒤에는 비워 다음 일정에 따라가지 않게 한다.
    @State private var place: TravelItemPlace?
    @State private var isPickingPlace = false
    @State private var note = ""

    private var isEditing: Bool { target.editing != nil }

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// 가로로 눕힌 폰처럼 높이가 낮으면 시트를 끝까지 올리고 안을 스크롤한다(자판이 올라와도 이름 칸이 보이게).
    private var isShort: Bool { verticalSizeClass == .compact }

    static func sheetHeight(hasAdded: Bool, hasSuggestions: Bool) -> CGFloat {
        320 + (hasAdded ? 40 : 0) + (hasSuggestions ? 38 : 0)
    }

    var body: some View {
        Group {
            if isShort { ScrollView { form } } else { form }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TravelInk.land)
        .presentationDetents(isShort ? [.large] : [.height(Self.sheetHeight(hasAdded: added != nil, hasSuggestions: !suggestions.isEmpty))])
        // 패드·펼친 듀오에서는 가운데 뜨는 시트를 내용 높이에 맞춘다.
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
        .onAppear(perform: prepare)
        .onChange(of: text) { _, value in read(value) }
        .sheet(isPresented: $isPickingPlace) {
            TravelPlacePicker(language: language, query: TravelQuickEntry.parse(text).title, anchor: target.anchor) { picked in
                place = picked
                // 이름을 아직 안 썼으면 고른 곳 이름을 쓴다.
                if TravelQuickEntry.parse(text).title.isEmpty { text = picked.name }
            }
        }
    }

    /// 장소 줄: 붙이면 지도에 핀이 생긴다.
    private var placeRow: some View {
        HStack(spacing: 6) {
            Button { isPickingPlace = true } label: {
                Label(place?.name ?? language.text("장소 붙이기", "Add a place"), systemImage: place == nil ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .font(.footnote.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 30)
                    .foregroundStyle(place == nil ? TravelInk.plan : TravelInk.land)
                    .background(place == nil ? TravelInk.planTint : TravelInk.plan, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("travelEntryPlace")
            if place != nil {
                Button { place = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(TravelInk.plan.opacity(0.6)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("장소 떼기", "Remove place"))
            }
            Spacer(minLength: 0)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let added { addedRow(added) }
            kindChips
            timeRow
            durationChips
            if !suggestions.isEmpty { suggestionChips }
            placeRow
            titleRow
            TextField(language.text("메모 (선택)", "Note (optional)"), text: $note)
                .font(.footnote)
                .padding(.horizontal, 10).frame(height: 34)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(TravelInk.border, lineWidth: 1) }
                .accessibilityIdentifier("travelEntryNote")
            if didFail {
                Text(language.text("넣지 못했습니다. 다시 해 주세요.", "Could not save. Try again.")).font(.caption).foregroundStyle(TravelInk.actual)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
        // 넓은 시트에서도 칩과 이름 칸이 한눈에 들어오게 폭을 묶는다.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack {
            Text(target.dayLabel + " · " + (isEditing ? language.text("일정 고치기", "Edit plan") : language.text("일정 넣기", "Add plan")))
                .font(.headline).foregroundStyle(TravelInk.plan)
            Spacer()
            if isEditing {
                // 자주 하는 고치기는 한 번에: 바로 뒤에 복제, 하루 옮기기, 지우기.
                Menu {
                    Button(language.text("바로 뒤에 복제", "Duplicate right after"), systemImage: "plus.square.on.square") { Task { await duplicate() } }
                    Button(language.text("전날로", "Move to previous day"), systemImage: "arrow.left") { Task { await shiftDay(-1) } }
                    Button(language.text("다음 날로", "Move to next day"), systemImage: "arrow.right") { Task { await shiftDay(1) } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(TravelInk.plan).frame(width: 40, height: 32)
                }
                .accessibilityLabel(language.text("더 보기", "More"))
                .accessibilityIdentifier("travelEntryMore")
                // 바로 지우지 않고 한 번 묻는다(Trip과 같게).
                Button(language.text("지우기", "Delete"), role: .destructive) { isConfirmingDelete = true }
                    .accessibilityIdentifier("travelEntryDelete")
                    .confirmationDialog(language.text("이 일정을 지울까요?", "Delete this plan?"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                        Button(language.text("지우기", "Delete"), role: .destructive) { Task { await remove() } }
                    }
            } else {
                Button(language.text("완료", "Done")) { dismiss() }.accessibilityIdentifier("travelEntryDone")
            }
        }
    }

    private func addedRow(_ added: (itemID: String, summary: String)) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
            Text(added.summary).lineLimit(1)
            Spacer()
            Button(language.text("되돌리기", "Undo")) { Task { await undo(added.itemID) } }.accessibilityIdentifier("travelEntryUndo")
        }
        .font(.footnote)
        .foregroundStyle(TravelInk.plan)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(TravelInk.planTint, in: RoundedRectangle(cornerRadius: 8))
    }

    private var kindChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Self.kinds, id: \.self) { option in
                    Button { choose(option) } label: {
                        Label(option.planName, systemImage: option.symbol).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).frame(height: 34)
                            .foregroundStyle(option == kind ? TravelInk.land : TravelInk.plan)
                            .background(option == kind ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == kind ? .isSelected : [])
                    .accessibilityIdentifier("travelEntryKind-\(option.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var timeRow: some View {
        HStack(spacing: 10) {
            stepButton("minus", language.text("15분 앞으로", "15 minutes earlier")) { startMinute = max(0, startMinute - TravelQuickEntry.step) }
            Text(Self.clock(startMinute) + " – " + Self.clock(startMinute + duration))
                .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(TravelInk.plan)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("travelEntryTime")
            stepButton("plus", language.text("15분 뒤로", "15 minutes later")) { startMinute = min(1_440 - TravelQuickEntry.step, startMinute + TravelQuickEntry.step) }
        }
    }

    private func stepButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).frame(width: 44, height: 36)
                .foregroundStyle(TravelInk.plan).background(TravelInk.planTint, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .accessibilityLabel(label)
    }

    private var durationChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(TravelQuickEntry.durations, id: \.self) { minutes in
                    Button {
                        duration = minutes
                        isDurationChosen = true
                    } label: {
                        Text(Self.durationText(minutes, language: language)).font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).frame(height: 30)
                            .foregroundStyle(minutes == duration ? TravelInk.land : TravelInk.plan)
                            .background(minutes == duration ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// 이름 후보: 이 여행에서 같은 분류로 이미 쓴 이름(최근 것부터 6개). 누르면 이름 칸에 들어간다.
    static func suggestions(items: [TravelTripItem], tripID: String, kind: TripImportItem.Kind, typed: String) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>(), result: [String] = []
        for item in items.reversed() where item.tripID == tripID && item.kind == kind.rawValue && item.title != kind.planName && item.title != typed {
            if seen.insert(item.title).inserted { result.append(item.title) }
            if result.count == 6 { break }
        }
        return result
    }

    private var suggestions: [String] {
        isEditing ? [] : Self.suggestions(items: model.settings.travelTripItems ?? [], tripID: target.tripID, kind: kind, typed: text)
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { title in
                    Button { text = title } label: {
                        Text(title).font(.footnote).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 28)
                            .foregroundStyle(TravelInk.plan)
                            .overlay { Capsule().stroke(TravelInk.border, lineWidth: 1) }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            TextField(language.text("이름 (예: 점심 12시 1시간)", "Name (e.g. lunch 12:30 1h)"), text: $text)
                .focused($isTitleFocused)
                .submitLabel(.done)
                .onSubmit { Task { await save() } }
                .padding(.horizontal, 10).frame(height: 44)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).stroke(TravelInk.border, lineWidth: 1) }
                .accessibilityIdentifier("travelEntryTitle")
            Button { Task { await save() } } label: {
                Text(isEditing ? language.text("고치기", "Save") : language.text("넣기", "Add")).font(.body.weight(.semibold))
                    .padding(.horizontal, 16).frame(height: 44)
                    .foregroundStyle(TravelInk.land).background(TravelInk.plan, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityIdentifier("travelEntrySave")
        }
    }

    // MARK: 움직임

    private func prepare() {
        kind = target.kind
        startMinute = target.startMinute
        place = target.place
        note = target.editing?.note ?? ""
        if let item = target.editing {
            text = item.title == target.kind.planName ? "" : item.title
            duration = max(5, Int(item.end.timeIntervalSince(item.start) / 60))
            isDurationChosen = true
        } else {
            duration = TravelQuickEntry.defaultDuration(kind: kind.rawValue)
            isTitleFocused = true
        }
    }

    private func choose(_ option: TripImportItem.Kind) {
        kind = option
        if !isDurationChosen { duration = TravelQuickEntry.defaultDuration(kind: option.rawValue) }
    }

    /// 이름 칸에 쓴 시각·길이·분류를 칩에 옮긴다. 새로 읽힌 값만 옮겨, 손으로 고른 값을 다시 덮지 않는다.
    private func read(_ value: String) {
        let next = TravelQuickEntry.parse(value)
        defer { parsed = next }
        if let minute = next.startMinute, minute != parsed.startMinute { startMinute = minute }
        if let minutes = next.durationMinutes, minutes != parsed.durationMinutes {
            duration = minutes
            isDurationChosen = true
        }
        if let found = next.kind.flatMap(TripImportItem.Kind.init(rawValue:)), next.kind != parsed.kind { choose(found) }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let title = TravelQuickEntry.parse(text).title
        let start = Self.date(dayKey: target.dayKey, minute: startMinute, offsetSeconds: target.offsetSeconds)
        let end = start.addingTimeInterval(TimeInterval(duration * 60))
        if let item = target.editing {
            didFail = !(await model.updateTripItem(
                tripID: item.tripID, itemID: item.itemID, kind: kind, title: title, start: start, end: end,
                place: place, replacesPlace: place != target.place, note: note
            ))
            if !didFail { dismiss() }
            return
        }
        guard let itemID = await model.addTripItem(
            tripID: target.tripID, kind: kind, title: title, start: start, end: end, offsetSeconds: target.offsetSeconds, place: place, note: note
        ) else {
            didFail = true
            return
        }
        didFail = false
        added = (itemID, Self.clock(startMinute) + "–" + Self.clock(startMinute + duration) + " " + (title.isEmpty ? kind.planName : title))
        // 다음 일정은 방금 끝에서 잇는다.
        startMinute = TravelQuickEntry.nextStart(lastEndMinute: startMinute + duration, nowMinute: nil)
        text = ""
        note = ""
        place = nil
        parsed = TravelQuickEntry.Parsed(title: "")
        isDurationChosen = false
        duration = TravelQuickEntry.defaultDuration(kind: kind.rawValue)
        isTitleFocused = true
    }

    private func undo(_ itemID: String) async {
        guard let item = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == target.tripID && $0.itemID == itemID }) else {
            added = nil
            return
        }
        let local = Int(item.start.timeIntervalSince1970) + item.startOffsetSeconds
        if await model.deleteTripItem(tripID: target.tripID, itemID: itemID) {
            startMinute = ((local % 86_400) + 86_400) % 86_400 / 60
            added = nil
        }
    }

    /// 같은 종류·이름·길이로 바로 뒤에 하나 더 넣는다.
    private func duplicate() async {
        guard let item = target.editing else { return }
        let length = item.end.timeIntervalSince(item.start)
        let added = await model.addTripItem(
            tripID: item.tripID, kind: TripImportItem.Kind(rawValue: item.kind) ?? .other, title: item.title,
            start: item.end, end: item.end.addingTimeInterval(length), offsetSeconds: item.endOffsetSeconds
        )
        didFail = added == nil
        if !didFail { dismiss() }
    }

    private func shiftDay(_ days: Int) async {
        guard let item = target.editing else { return }
        didFail = !(await model.moveTripItem(tripID: item.tripID, itemID: item.itemID, by: TimeInterval(days * 86_400)))
        if !didFail { dismiss() }
    }

    private func remove() async {
        guard let item = target.editing else { return }
        didFail = !(await model.deleteTripItem(tripID: item.tripID, itemID: item.itemID))
        if !didFail { dismiss() }
    }
}
