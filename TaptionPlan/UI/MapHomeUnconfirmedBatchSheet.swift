import SwiftUI

/// 미확인 구간 여러 개를 골라 한 분류로 한 번에 정한다(대표 지시 2026-11-11, UNC1111A01).
/// 사이드바의 「?」 묶음을 누르면 뜬다. 처음엔 모두 고른 상태이고, 줄을 눌러 빼거나 넣는다.
/// 분류를 누르면 고른 구간 전부를 한 번에 저장하고(되돌리기 한 칸) 닫는다. 「›」는 그 구간 하나만 자세히 고친다.
struct MapHomeUnconfirmedBatchSheet: View {
    let segments: [MapHomeTimeRailSegment]
    let timeLabel: (Int) -> String
    let onOpenOne: (MapHomeTimeRailSegment) -> Void
    let onConfirm: ([MapHomeTimeRailSegment], MapHomeSidebarMajorCategory) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var isSaving = false
    @State private var failed = false
    /// 「›」로 고른 구간. 이 창이 다 닫힌 뒤에 그 구간 창을 연다(닫히는 중에 다른 창을 띄우면 무시된다).
    @State private var openAfterClose: MapHomeTimeRailSegment?

    private var categories: [MapHomeSidebarMajorCategory] { MapHomeUnconfirmedBatch.quickCategories }

    private var language: MapHomeLanguage { .current }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(segments, id: \.id) { segment in
                        HStack(spacing: 12) {
                            Image(systemName: picked.contains(segment.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(picked.contains(segment.id) ? Color.tpAccent : Color.tpSecondary)
                            Text("\(timeLabel(segment.startMinute))–\(timeLabel(segment.endMinute))")
                                .foregroundStyle(Color.tpInk)
                            Spacer()
                            Button { openAfterClose = segment; dismiss() } label: { Image(systemName: "chevron.right") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.tpSecondary)
                                .accessibilityLabel(language.text("이 구간만 자세히", "Edit this one"))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(segment.id) }
                    }
                } header: {
                    HStack {
                        Text(language.text("고른 구간 \(picked.count)개", "\(picked.count) picked"))
                        Spacer()
                        Button(picked.count == segments.count ? language.text("모두 빼기", "Deselect all") : language.text("모두 고르기", "Select all")) {
                            picked = picked.count == segments.count ? [] : Set(segments.map(\.id))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                        ForEach(categories) { category in
                            Button { Task { await confirm(category) } } label: {
                                Label(category.localizedTitle(language), systemImage: category.systemImage)
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 36)
                            }
                            .buttonStyle(.bordered)
                            .disabled(picked.isEmpty || isSaving)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text(language.text("고른 구간 모두 이 분류로", "Set all picked to"))
                } footer: {
                    if failed {
                        Text(language.text("저장하지 못했어요. 기록은 바뀌지 않았어요.", "Couldn't save. Nothing changed."))
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(language.text("미확인 구간 고르기", "Choose unconfirmed intervals"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(language.text("닫기", "Close")) { dismiss() } } }
            .onAppear { picked = Set(segments.map(\.id)) }
            .onDisappear {
                guard let segment = openAfterClose else { return }
                openAfterClose = nil
                Task { @MainActor in
                    await Task.yield()
                    onOpenOne(segment)
                }
            }
            .overlay { if isSaving { ProgressView() } }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggle(_ id: String) {
        UISelectionFeedbackGenerator().selectionChanged()
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    private func confirm(_ category: MapHomeSidebarMajorCategory) async {
        isSaving = true
        failed = false
        let chosen = segments.filter { picked.contains($0.id) }
        let saved = await onConfirm(chosen, category)
        isSaving = false
        if saved { dismiss() } else { failed = true }
    }
}

extension MapHomeView {
    /// 미확인 구간 여러 개를 한 분류로 한 번에 저장한다. 실패하면 하나도 바뀌지 않는다(클립 편집과 같은 일괄 저장).
    func quickConfirmUnconfirmed(_ segments: [MapHomeTimeRailSegment], as category: MapHomeSidebarMajorCategory) async -> Bool {
        guard model.isBootstrapped else { return false }
        let calendar = Calendar.autoupdatingCurrent
        let selectedDay = model.selectedDate
        let requests = segments.compactMap { MapHomeUnconfirmedBatch.request(for: $0, category: category, day: selectedDay, calendar: calendar) }
        guard !requests.isEmpty, await model.saveClipEditBatch(main: requests, detail: []) else { return false }
        refreshTimeRailSegments()
        if let first = segments.first, calendar.isDate(model.selectedDate, inSameDayAs: selectedDay) {
            selectedTimelineMinute = MapHomeUnconfirmedReviewPolicy.midpointMinute(for: first)
            isTimelineSelectionPinned = true
        }
        rewardRecentCompletedDay(selectedDay)
        return true
    }
}

enum MapHomeUnconfirmedBatch {
    /// 미확인을 바로 정할 때 보이는 분류. 하나씩 정하는 창과 여러 개 정하는 창이 같이 쓴다.
    static let quickCategoryIDs = ["work", "study", "sleep", "eating", "movement", "exercise", "hobby", "activity"]

    static var quickCategories: [MapHomeSidebarMajorCategory] {
        let byID = Dictionary(uniqueKeysWithValues: MapHomeSidebarMajorCategory.all.map { ($0.id, $0) })
        return quickCategoryIDs.compactMap { byID[$0] }
    }

    /// 한 미확인 구간을 그 분류로 바꾸는 요청. 하나씩 정할 때(`quickConfirmUnconfirmed`)와 같은 모양이다.
    static func request(
        for segment: MapHomeTimeRailSegment, category: MapHomeSidebarMajorCategory, day: Date, calendar: Calendar
    ) -> ActivitySectionEditRequest? {
        let startOfDay = calendar.startOfDay(for: day)
        guard segment.categoryID == "unconfirmed", segment.startMinute < segment.endMinute,
              let start = calendar.date(byAdding: .minute, value: segment.startMinute, to: startOfDay),
              let end = calendar.date(byAdding: .minute, value: segment.endMinute, to: startOfDay) else { return nil }
        let original = ActivityCorrectionOption(
            id: "phase.unconfirmed", title: segment.title, behavior: segment.behavior,
            categoryID: "unconfirmed", systemImage: "questionmark", isAutomatic: false, isCustom: false
        )
        let choice = ActivityCorrectionOption(
            id: "phase.\(category.id)", title: category.title, behavior: nil,
            categoryID: category.id, systemImage: category.systemImage, isAutomatic: false, isCustom: false
        )
        let span = TimeSpan(start: start, end: end)
        return ActivitySectionEditRequest(
            sourceIDs: segment.sourceIDs, originalSpan: span, originalOption: original,
            mode: .replace(editedSpan: span, option: choice)
        )
    }
}
