import SwiftUI
import TaptionPlanStore

/// 여행 일정 편집기(TVQ1112A01 → TVU1113A01에서 Trip 편집기 순서로): 종류·제목 → 미리보기 카드·메모 → 시작/종료 슬라이더 → 장소. 저장하면 닫힌다. 넣기와 고치기가 같은 화면이다.
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
        /// 새 일정의 시차를 정할 여행(출국 비행 전은 출발지, 도착부터는 여행지: `TravelTimeZones`). 고칠 때는 nil.
        var trip: TravelTrip?
        /// 고칠 일정. 없으면 새로 넣는다.
        var editing: TravelTripItem?
        /// 장소를 찾을 때 먼저 볼 여행지 가운데(경도, 위도)와, 고칠 일정에 이미 붙은 장소.
        var anchor: SIMD2<Double>?
        var place: TravelItemPlace?
        /// 계획표에서 셀 길이를 정하고 열었으면 그 길이(분).
        var duration: Int?
        /// 코스 곳에 딸린 세부 계획으로 넣을 때 그 곳의 일정 번호.
        var parentItemID: String?

        /// 새 일정: 그 여행의 시간대(없으면 기기 시간대)로 그날에 놓는다.
        static func new(trip: TravelTrip, dayKey: String, dayLabel: String, startMinute: Int, kind: TripImportItem.Kind) -> Target {
            let zone = trip.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .autoupdatingCurrent
            let noon = TravelQuickEntrySheet.date(dayKey: dayKey, minute: 720, offsetSeconds: zone.secondsFromGMT())
            return Target(tripID: trip.id, dayKey: dayKey, dayLabel: dayLabel, startMinute: startMinute, kind: kind, offsetSeconds: zone.secondsFromGMT(for: noon), trip: trip)
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
    /// 일정을 넣거나 지웠을 때 되돌릴 수 있게 그 걸음을 알린다.
    var onHistory: (TravelPlanHistory.Step) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFocused: Bool
    @State private var text = ""
    @State private var kind = TripImportItem.Kind.sight
    @State private var startMinute = 540
    @State private var duration = 60
    /// 길이를 직접 골랐으면 분류를 바꿔도 그대로 둔다.
    @State private var isDurationChosen = false
    @State private var parsed = TravelQuickEntry.Parsed(title: "")
    @State private var isSaving = false
    @State private var didFail = false
    /// 캘린더 고정 세부가 있는 곳을 다른 날로 옮길 때 묻는 창(대표 결정 2026-11-18).
    @State private var fixedQuestion: TravelFixedMoveQuestion?
    @State private var isConfirmingDelete = false
    /// 붙인 장소(지도 핀).
    @State private var place: TravelItemPlace?
    @State private var isPickingPlace = false
    @State private var note = ""
    /// 일정 색(nil이면 기본 남색)과 예상 지출(원, 숫자만).
    @State private var colorHex: String?
    @State private var plannedSpend = ""

    /// 예상 지출 칸의 글에서 숫자만 남긴다(쉼표·원 표시를 붙여 넣어도 된다).
    static func spendDigits(_ text: String) -> String { String(text.filter(\.isNumber).prefix(10)) }

    private var isEditing: Bool { target.editing != nil }

    /// 새 일정의 시작·끝 시차: 그 날짜·시각이 비행 전이면 출발지, 도착 뒤면 여행지. 비행은 출발지에서 떠나 도착지에 닿는다.
    private var newOffsets: (start: Int, end: Int) {
        guard target.editing == nil, let trip = target.trip else { return (target.offsetSeconds, target.offsetSeconds) }
        let items = model.settings.travelTripItems ?? []
        if kind == .flight { return TravelTimeZones.flightOffsets(trip: trip, items: items, dayKey: target.dayKey, minute: startMinute) }
        let offset = TravelTimeZones.offset(trip: trip, items: items, dayKey: target.dayKey, minute: startMinute)
        return (offset, offset)
    }

    /// 미리보기의 시각 줄. 시차가 다른 비행은 도착 시각을 도착지 현지 시각으로 보이고 양쪽에 시차(GMT+N)를 붙인다.
    private var timeLine: String {
        let offsets = newOffsets
        let shift = (offsets.end - offsets.start) / 60
        let text = Self.clock(startMinute) + " – " + Self.clock(startMinute + duration + shift)
        guard shift != 0 else { return text + " · " + Self.durationText(duration, language: language) }
        return "\(Self.clock(startMinute)) (\(Self.gmt(offsets.start))) – \(Self.clock(startMinute + duration + shift)) (\(Self.gmt(offsets.end))) · "
            + Self.durationText(duration, language: language)
    }

    static func gmt(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+", total = abs(seconds) / 60
        return total % 60 == 0 ? "GMT\(sign)\(total / 60)" : String(format: "GMT%@%d:%02d", sign, total / 60, total % 60)
    }
    /// 슬라이더 단위(분). Trip 원본처럼 5분.
    static let sliderStep = 5

    /// 시작 슬라이더: 길이는 그대로 두고 옮기되, 끝이 24시를 넘으면 길이를 줄인다.
    /// 이미 자정을 넘는 일정(밤 비행·잠)은 `previous`(옮기기 전 시작)로 알아보고 길이를 줄이지 않는다.
    static func movingStart(to minute: Int, duration: Int, from previous: Int? = nil, maxEnd: Int = 1_440) -> (start: Int, duration: Int) {
        let start = min(max(minute / sliderStep * sliderStep, 0), 1_440 - sliderStep)
        if let previous, previous + duration > 1_440 { return (start, duration) }
        return (start, min(max(duration, sliderStep), maxEnd - start))
    }

    /// 종료 슬라이더의 끝(분). 자정을 넘기는 종류(비행·이동·숙소·잠)는 다음 날 24시까지, 나머지는 그날 24시까지.
    static func maxEnd(for kind: TripImportItem.Kind) -> Int {
        switch kind {
        case .flight, .transfer, .lodging, .sleep: 2_880
        default: 1_440
        }
    }

    /// 종료 슬라이더: 시작보다 5분 이상 뒤, 24시까지. 돌려주는 값은 길이(분).
    static func duration(endingAt minute: Int, start: Int, maxEnd: Int = 1_440) -> Int {
        max(sliderStep, min(minute / sliderStep * sliderStep, maxEnd) - start)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(TravelInk.border)
            ScrollView { form }.scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(TravelInk.land)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.light)
        .onAppear(perform: prepare)
        .tripSharePlanEditing(target.editing, language: language)
        .onChange(of: text) { _, value in read(value) }
        .sheet(isPresented: $isPickingPlace) {
            TravelPlacePicker(language: language, query: TravelQuickEntry.parse(text).title, anchor: target.anchor) { picked in
                place = picked
                // 이름을 아직 안 썼으면 고른 곳 이름을 쓴다.
                if TravelQuickEntry.parse(text).title.isEmpty { text = picked.name }
            }
        }
    }

    /// 함께 쓰는 여행에서 일행이 붙인 장소는 이름만 온다(핀 없음, TSH1114A26).
    private var sharedPlaceName: String? { target.editing.flatMap { TripSharePlanEditor.placeName(tripID: $0.tripID, itemID: $0.itemID) } }

    /// 장소 줄: 붙이면 지도에 핀이 생긴다.
    private var placeRow: some View {
        HStack(spacing: 6) {
            Button { isPickingPlace = true } label: {
                Label(place?.name ?? sharedPlaceName ?? language.text("장소 붙이기", "Add a place"), systemImage: place == nil ? "mappin.and.ellipse" : "mappin.circle.fill")
                    .font(.footnote.weight(.medium)).lineLimit(1)
                    .padding(.horizontal, 10).frame(height: TaptionControl.chip)
                    .foregroundStyle(place == nil ? TravelInk.plan : TravelInk.land)
                    .background(place == nil ? TravelInk.planTint : TravelInk.plan, in: Capsule())
                    .taptionTouchTarget(visualWidth: TaptionControl.primary, visualHeight: TaptionControl.chip)
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
        VStack(alignment: .leading, spacing: 12) {
            kindChips
            titleField
            if !suggestions.isEmpty { suggestionChips }
            previewCard
            timeSliders
            placeRow
            styleRows
            if isEditing { editActions }
            if didFail {
                Text(language.text("넣지 못했습니다. 다시 해 주세요.", "Could not save. Try again.")).font(.caption).foregroundStyle(TravelInk.actual)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 16)
        // 넓은 시트에서도 칩과 이름 칸이 한눈에 들어오게 폭을 묶는다.
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    /// 위 막대: 취소 · 「일정 넣기」/「속성」 · 저장.
    private var header: some View {
        HStack {
            Button(language.text("취소", "Cancel")) { dismiss() }.accessibilityIdentifier("travelEntryCancel")
            Spacer()
            Text(target.dayLabel + " · " + (isEditing ? language.text("속성", "Details") : language.text("일정 넣기", "Add plan")))
                .font(.headline).lineLimit(1)
            Spacer()
            Button(language.text("저장", "Save")) { Task { await save() } }
                .fontWeight(.semibold)
                .disabled(isSaving)
                .accessibilityIdentifier("travelEntrySave")
        }
        .foregroundStyle(TravelInk.plan)
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// 고칠 때만: 바로 뒤에 복제·하루 옮기기와 지우기(한 번 묻는다).
    private var editActions: some View {
        HStack {
            Menu {
                Button(language.text("바로 뒤에 복제", "Duplicate right after"), systemImage: "plus.square.on.square") { Task { await duplicate() } }
                Button(language.text("전날로", "Move to previous day"), systemImage: "arrow.left") { Task { await shiftDay(-1) } }
                Button(language.text("다음 날로", "Move to next day"), systemImage: "arrow.right") { Task { await shiftDay(1) } }
                if let item = target.editing {
                    TravelDayMoveMenu(model: model, item: item, language: language, fixedQuestion: $fixedQuestion) { step in
                        didFail = step == nil
                        if let step {
                            onHistory(step)
                            dismiss()
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(TravelInk.plan).frame(width: TaptionControl.round, height: TaptionControl.chip)
                    .taptionMenuHitFrame(visualWidth: TaptionControl.round, visualHeight: TaptionControl.chip)
            }
            .taptionMenuHitLayout(visualWidth: TaptionControl.round, visualHeight: TaptionControl.chip)
            .accessibilityLabel(language.text("더 보기", "More"))
            .accessibilityIdentifier("travelEntryMore")
            Spacer()
            Button(language.text("지우기", "Delete"), role: .destructive) { isConfirmingDelete = true }
                .accessibilityIdentifier("travelEntryDelete")
                .confirmationDialog(language.text("이 일정을 지울까요?", "Delete this plan?"), isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button(language.text("지우기", "Delete"), role: .destructive) { Task { await remove() } }
                }
                .travelFixedMoveQuestion($fixedQuestion, language: language)
        }
    }

    /// Trip 편집기의 색 팔레트와 예상 지출: 색 견본(기본 + 여섯 색)과 금액 칸.
    private var styleRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                colorButton(nil)
                ForEach(TravelInk.flagHexes, id: \.self) { colorButton($0) }
            }
            HStack(spacing: 8) {
                Label(language.text("예상 지출", "Planned spend"), systemImage: "wonsign.circle").font(.footnote.weight(.medium)).foregroundStyle(TravelInk.plan)
                TextField("0", text: $plannedSpend)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .font(.footnote.monospacedDigit())
                    .padding(.horizontal, 10).frame(height: 34)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: TaptionCorner.small))
                    .overlay { RoundedRectangle(cornerRadius: TaptionCorner.small).stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
                    .onChange(of: plannedSpend) { _, value in
                        let digits = Self.spendDigits(value)
                        if digits != value { plannedSpend = digits }
                    }
                    .accessibilityLabel(language.text("예상 지출", "Planned spend"))
                    .accessibilityIdentifier("travelEntryPlannedSpend")
            }
        }
    }

    private func colorButton(_ hex: String?) -> some View {
        Button { if colorHex != hex { colorHex = hex } } label: {
            Image(uiImage: TravelInk.swatch(hex ?? "#2F3E6B", isChosen: colorHex == hex, side: 30))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hex == nil ? language.text("기본 색으로", "Use default color") : language.runtimeText("색 \(hex ?? "")", "Color \(hex ?? "")"))
        .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
        .accessibilityIdentifier("travelEntryColor-" + (hex ?? "default"))
    }

    /// 미리보기 카드: 계획표에 놓일 모습(이름·시각·장소)과 메모.
    private var previewCard: some View {
        let title = TravelQuickEntry.parse(text).title
        return VStack(alignment: .leading, spacing: 4) {
            Label(title.isEmpty ? kind.planName : title, systemImage: kind.symbol).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(timeLine)
                .font(.footnote.monospacedDigit()).opacity(0.8)
                .accessibilityIdentifier("travelEntryTime")
            if let place { Label(place.name, systemImage: "mappin.circle.fill").font(.footnote).lineLimit(1).opacity(0.8) }
            TextField(language.text("메모 (선택)", "Note (optional)"), text: $note, axis: .vertical)
                .font(.footnote).lineLimit(1...3)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: TaptionCorner.small))
                .padding(.top, 4)
                .accessibilityIdentifier("travelEntryNote")
        }
        .foregroundStyle(TravelInk.plan)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TravelPlanTable.tint(colorHex), in: RoundedRectangle(cornerRadius: TaptionCorner.medium))
        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium).stroke(TravelPlanTable.ink(colorHex), lineWidth: 1) }
    }

    /// 시작·종료 슬라이더(5분 단위). 시작을 옮기면 길이는 그대로 따라간다.
    private var timeSliders: some View {
        VStack(spacing: 6) {
            timeSlider(language.text("시작", "Start"), minute: startMinute, range: 0...Double(1_440 - Self.sliderStep), id: "Start") { value in
                let next = Self.movingStart(to: value, duration: duration, from: startMinute, maxEnd: Self.maxEnd(for: kind))
                if next.start != startMinute { startMinute = next.start }
                if next.duration != duration { duration = next.duration }
            }
            timeSlider(language.text("종료", "End"), minute: startMinute + duration, range: Double(Self.sliderStep)...Double(Self.maxEnd(for: kind)), id: "End") { value in
                let next = Self.duration(endingAt: value, start: startMinute, maxEnd: Self.maxEnd(for: kind))
                if next != duration {
                    duration = next
                    isDurationChosen = true
                }
            }
        }
    }

    private func timeSlider(_ label: String, minute: Int, range: ClosedRange<Double>, id: String, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.footnote.weight(.medium)).frame(width: 34, alignment: .leading)
            Slider(value: Binding(get: { Double(minute) }, set: { set(Int($0.rounded())) }), in: range, step: Double(Self.sliderStep))
                .tint(TravelInk.plan)
                .accessibilityLabel(label)
                .accessibilityValue(Self.clock(minute))
                .accessibilityIdentifier("travelEntry" + id)
            Text(minute == 1_440 ? "24:00" : Self.clock(minute)).font(.footnote.weight(.medium).monospacedDigit()).frame(width: 44, alignment: .trailing)
        }
        .foregroundStyle(TravelInk.plan)
    }

    private var kindChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Self.kinds, id: \.self) { option in
                    Button { choose(option) } label: {
                        Label(option.planName, systemImage: option.symbol).font(.footnote.weight(.medium))
                            .padding(.horizontal, 10).frame(height: TaptionControl.chip)
                            .foregroundStyle(option == kind ? TravelInk.land : TravelInk.plan)
                            .background(option == kind ? TravelInk.plan : TravelInk.planTint, in: Capsule())
                            .taptionTouchTarget(visualWidth: TaptionControl.primary, visualHeight: TaptionControl.chip)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == kind ? .isSelected : [])
                    .accessibilityIdentifier("travelEntryKind-\(option.rawValue)")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// 이름 후보: 이 여행에서 같은 분류로 이미 쓴 이름(최근 것부터 6개). 누르면 이름 칸에 들어간다.
    /// 이동이면 탈것(`vehicles`)을 앞에 둔다: 누르면 이름이 되고 고양이 동작도 그 탈것이 된다.
    static func suggestions(items: [TravelTripItem], tripID: String, kind: TripImportItem.Kind, typed: String, vehicles: [String] = []) -> [String] {
        let typed = typed.trimmingCharacters(in: .whitespaces)
        let first = kind == .transfer ? vehicles.filter { $0 != typed } : []
        var seen = Set(first), result: [String] = []
        for item in items.reversed() where item.tripID == tripID && item.kind == kind.rawValue && item.title != kind.planName && item.title != typed {
            if seen.insert(item.title).inserted { result.append(item.title) }
            if result.count == 6 { break }
        }
        return first + result
    }

    private var suggestions: [String] {
        isEditing ? [] : Self.suggestions(
            items: model.settings.travelTripItems ?? [], tripID: target.tripID, kind: kind, typed: text, vehicles: TravelPlanSpend.vehicles(language)
        )
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(suggestions, id: \.self) { title in
                    Button { text = title } label: {
                        Text(title).font(.footnote).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: TaptionControl.chip)
                            .foregroundStyle(TravelInk.plan)
                            .overlay { Capsule().stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
                            .taptionTouchTarget(visualWidth: TaptionControl.primary, visualHeight: TaptionControl.chip)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.hidden)
    }

    /// 제목 칸. 「점심 12시 1시간」처럼 쓰면 시각·길이·종류를 읽어 아래에 옮긴다. 리턴으로 저장.
    private var titleField: some View {
        TextField(language.text("이름 (예: 점심 12시 1시간)", "Name (e.g. lunch 12:30 1h)"), text: $text)
            .focused($isTitleFocused)
            .submitLabel(.done)
            .onSubmit { Task { await save() } }
            .padding(.horizontal, 10).frame(height: 44)
            .background(Color.white, in: RoundedRectangle(cornerRadius: TaptionCorner.medium))
            .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium).stroke(TravelInk.border, lineWidth: TaptionBorder.width) }
            .accessibilityIdentifier("travelEntryTitle")
    }

    // MARK: 움직임

    private func prepare() {
        kind = target.kind
        startMinute = target.startMinute
        place = target.place
        note = target.editing?.note ?? ""
        colorHex = target.editing?.colorHex
        plannedSpend = target.editing?.plannedSpendKRW.map { String(Int($0)) } ?? ""
        if let item = target.editing {
            text = item.title == target.kind.planName ? "" : item.title
            duration = max(5, Int(item.end.timeIntervalSince(item.start) / 60))
            isDurationChosen = true
        } else {
            duration = target.duration ?? TravelQuickEntry.defaultDuration(kind: kind.rawValue)
            isDurationChosen = target.duration != nil
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
        let offsets = newOffsets
        let start = Self.date(dayKey: target.dayKey, minute: startMinute, offsetSeconds: offsets.start)
        // 길이는 실제 비행·이동 시간이다. 끝은 시작에서 그만큼 뒤의 같은 순간이고, 비행이면 도착지 시차로 읽힌다.
        let end = start.addingTimeInterval(TimeInterval(duration * 60))
        if let item = target.editing {
            didFail = !(await TripSharePlanEditor.updateItem(
                model: model, tripID: item.tripID, itemID: item.itemID, kind: kind, title: title, start: start, end: end,
                place: place, replacesPlace: place != target.place, note: note, style: (colorHex, Double(plannedSpend))
            ))
        } else {
            let itemID = await TripSharePlanEditor.addItem(
                model: model, tripID: target.tripID, kind: kind, title: title, start: start, end: end, offsetSeconds: offsets.start, endOffsetSeconds: offsets.end, place: place, note: note,
                colorHex: colorHex, plannedSpendKRW: Double(plannedSpend), parentItemID: target.parentItemID
            )
            didFail = itemID == nil
            if let added = (model.settings.travelTripItems ?? []).first(where: { $0.tripID == target.tripID && $0.itemID == itemID }) {
                onHistory(.existence(added, place: place, exists: true))
            }
        }
        // Trip 원본처럼 저장하면 닫힌다.
        if !didFail { dismiss() }
    }

    /// 같은 종류·이름·길이로 바로 뒤에 하나 더 넣는다.
    private func duplicate() async {
        guard let item = target.editing else { return }
        let length = item.end.timeIntervalSince(item.start)
        let added = await TripSharePlanEditor.addItem(
            model: model, tripID: item.tripID, kind: TripImportItem.Kind(rawValue: item.kind) ?? .other, title: item.title,
            start: item.end, end: item.end.addingTimeInterval(length), offsetSeconds: item.endOffsetSeconds
        )
        didFail = added == nil
        if !didFail { dismiss() }
    }

    private func shiftDay(_ days: Int) async {
        guard let item = target.editing else { return }
        let delta = TimeInterval(days * 86_400)
        // 캘린더 고정 세부가 있으면 먼저 묻고, 「옮기기」면 앱 안에서 모두 옮긴다(대표 결정 2026-11-18).
        let fixed = TravelDayBoard.fixedCount(model: model, tripID: item.tripID, itemID: item.itemID)
        if fixed > 0 {
            fixedQuestion = .init(count: fixed) {
                Task { @MainActor in
                    didFail = !(await model.moveTripItem(tripID: item.tripID, itemID: item.itemID, by: delta, includingFixed: true))
                    if !didFail { dismiss() }
                }
            }
            return
        }
        didFail = !(await TripSharePlanEditor.moveItem(model: model, tripID: item.tripID, itemID: item.itemID, by: delta))
        if !didFail { dismiss() }
    }

    private func remove() async {
        guard let item = target.editing else { return }
        let step = await TripSharePlanEditor.deleteItem(model: model, tripID: item.tripID, itemID: item.itemID)
        didFail = step == nil
        if let step {
            onHistory(step)
            dismiss()
        }
    }
}
