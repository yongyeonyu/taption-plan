import SwiftUI
import TaptionPlanCore

/// 상세 클립이 들어갈 수 있는 빈 시간을 고른다(NLE1105A01).
enum NLESubClipPolicy {
    static let defaultMinutes = 30

    /// `minute`을 품는 빈 구간 안에서 `length`분을 잡는다. 이미 상세가 있으면 nil이다.
    static func freeSpan(
        around minute: Int,
        owner: Range<Int>,
        occupied: [Range<Int>],
        length: Int = defaultMinutes
    ) -> Range<Int>? {
        guard owner.contains(minute), !occupied.contains(where: { $0.contains(minute) }) else { return nil }
        let lower = occupied.map(\.upperBound).filter { $0 <= minute }.max().map { max($0, owner.lowerBound) } ?? owner.lowerBound
        let upper = occupied.map(\.lowerBound).filter { $0 > minute }.min().map { min($0, owner.upperBound) } ?? owner.upperBound
        let end = min(upper, minute + max(1, length))
        let start = max(lower, min(minute, end - max(1, length)))
        return start < end ? start..<end : nil
    }
}

/// 클립 편집기의 상세 활동 줄과 그 메뉴.
extension MapHomeNLEClipEditor {
    /// 지운 상세는 대분류로 돌아가 있으므로 그리지 않는다.
    var visibleSubClips: [NLEClip] {
        subTrack.clips.filter { $0.option != $0.parent.fillOption }
    }

    func subClip(atMinute minute: Int) -> NLEClip? {
        visibleSubClips.first { $0.contains(minute: minute) }
    }

    func detailColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(visibleSubClips) { clip in
                let height = max(3, geometry.height(minutes: Double(clip.lengthMinutes)) - 2)
                detailBar(clip, height: height)
                    .frame(width: width, height: height)
                    .offset(y: geometry.y(forMinute: Double(clip.startMinute)) + 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
        .allowsHitTesting(false)
    }

    private func detailBar(_ clip: NLEClip, height: CGFloat) -> some View {
        let isSelected = clip.id == selectedSubClipID
        return RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Self.tint(for: clip.option.categoryID).opacity(0.88))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.95 : 0.35), lineWidth: isSelected ? 2 : 0.7)
            }
            .overlay(alignment: .topLeading) {
                if height >= 15 {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(RecordClassificationCatalog.localizedDetailTitle(clip.option.title, language: language))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        if height >= 28 {
                            Text("\(Self.minuteLabel(clip.startMinute))–\(Self.minuteLabel(clip.endMinute))")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 5)
                    .padding(.top, 2)
                    // 줄이 화면 밖으로 넘치는 폭만큼 글자를 안쪽에서 끊는다.
                    .padding(.trailing, 4 + Self.railBleed * 2)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(RecordClassificationCatalog.localizedDetailTitle(clip.option.title, language: language))
    }

    /// 상세 항목이 속한 대분류 클립. 상세를 골랐으면 그 자리, 아니면 재생 헤드 자리다.
    private var detailOwner: NLEClip? {
        let minute = activeSubClipForMenu?.startMinute ?? min(playheadMinute, NLETrack.dayMinutes - 1)
        return track.clip(atMinute: minute).flatMap { $0.isGap ? nil : $0 }
    }

    private var activeSubClipForMenu: NLEClip? {
        selectedSubClipID.flatMap { subTrack.clip($0) }
    }

    /// 그 대분류의 상세 항목만 보여 준다(위계 구조).
    private var ownerDetails: [RecordClassificationDetail] {
        detailOwner.map { MapHomeCategoryDetailRows.details(for: $0.option.categoryID) } ?? []
    }

    private var dayEvents: [CalendarRecord] {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return model.snapshot.calendarEvents
            .filter { !$0.isAllDay && $0.span.start < end && $0.span.end > start }
            .sorted { $0.span.start < $1.span.start }
    }

    private func detailTitle(_ detail: RecordClassificationDetail) -> String {
        RecordClassificationCatalog.detailTitle(
            categoryID: detailOwner?.option.categoryID ?? "",
            behavior: detail.behavior
        ) ?? detail.title
    }

    var detailMenu: some View {
        Menu {
            ForEach(ownerDetails) { detail in
                Button {
                    applyDetail(title: detailTitle(detail), behavior: detail.behavior)
                } label: {
                    Label(detail.localizedTitle(language), systemImage: detail.systemImage)
                }
            }
            if let owner = detailOwner, !MapHomeCategoryDetailRows.userAddedDetails(for: owner.option.categoryID).isEmpty {
                // 센서로 알 수 없는 상세는 직접 고를 때만 붙는다(DTL1111A01).
                Section(language.text("직접 추가", "Add your own")) {
                    ForEach(MapHomeCategoryDetailRows.userAddedDetails(for: owner.option.categoryID)) { detail in
                        Button {
                            applyDetail(title: detailTitle(detail), behavior: detail.behavior)
                        } label: {
                            Label(detail.localizedTitle(language), systemImage: detail.systemImage)
                        }
                    }
                }
            }
            if !dayEvents.isEmpty {
                Section(language.text("일정에서 고르기", "From calendar")) {
                    ForEach(dayEvents) { event in
                        Button {
                            addDetail(from: event)
                        } label: {
                            Label(event.title, systemImage: event.isGoogleAccountEvent ? "g.circle" : "calendar")
                        }
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                Text(language.text("상세", "Detail"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(Color.tpInk)
            .frame(minWidth: 44, minHeight: TaptionMenuMetrics.minimumHitSize)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("nleDetailMenu")
        .disabled(detailOwner == nil)
        .opacity(detailOwner == nil ? 0.45 : 1)
    }

    /// 상세를 골랐으면 항목을 바꾸고, 아니면 재생 헤드 자리에 새로 넣는다.
    private func applyDetail(title: String, behavior: String?) {
        guard let owner = detailOwner else { return }
        let option = Self.option(forCategoryID: owner.option.categoryID, title: title, behavior: behavior)
        if let active = activeSubClipForMenu {
            pushUndo()
            subTrack.setOption(active.id, to: option)
            return
        }
        insertDetail(option, owner: owner, minute: min(playheadMinute, NLETrack.dayMinutes - 1), length: NLESubClipPolicy.defaultMinutes)
    }

    private func addDetail(from event: CalendarRecord) {
        let dayStart = Calendar.autoupdatingCurrent.startOfDay(for: date)
        let minute = max(0, Int(event.span.start.timeIntervalSince(dayStart) / 60))
        guard let owner = track.clip(atMinute: min(minute, NLETrack.dayMinutes - 1)), !owner.isGap else { return }
        let option = Self.option(
            forCategoryID: owner.option.categoryID,
            title: event.title,
            behavior: MapHomeMeetingPolicy.isMeeting(event) ? StationaryContextKind.meeting.rawValue : nil
        )
        insertDetail(option, owner: owner, minute: minute, length: max(1, Int(event.span.duration / 60)))
    }

    private func insertDetail(_ option: ActivityCorrectionOption, owner: NLEClip, minute: Int, length: Int) {
        guard let span = NLESubClipPolicy.freeSpan(
            around: minute,
            owner: owner.startMinute..<owner.endMinute,
            occupied: visibleSubClips.map { $0.startMinute..<$0.endMinute },
            length: length
        ) else { return }
        pushUndo()
        let id = "sub-new-\(UUID().uuidString)"
        subTrack.insert(NLEClip(
            id: id,
            option: option,
            startMinute: span.lowerBound,
            endMinute: span.upperBound,
            parent: NLEClipParent(
                startMinute: owner.parent.startMinute,
                endMinute: owner.parent.endMinute,
                sourceIDs: owner.parent.sourceIDs,
                option: owner.parent.option,
                fillOption: owner.option
            ),
            origin: NLEClipOrigin(startMinute: span.lowerBound, endMinute: span.upperBound, option: owner.option)
        ))
        selectedSubClipID = id
    }

    /// 기본 대분류 뒤에 사용자가 만든 분류를 따로 묶는다. 메뉴가 위로 열려 맨 위에 와도 기본 분류와 섞여 보이지 않는다.
    @ViewBuilder
    func categoryButtons(
        _ categories: [MapHomeSidebarMajorCategory],
        apply: @escaping (MapHomeSidebarMajorCategory) -> Void
    ) -> some View {
        let custom = categories.filter { $0.id.hasPrefix("custom:") }
        ForEach(categories.filter { !$0.id.hasPrefix("custom:") }) { categoryButton($0, apply: apply) }
        if !custom.isEmpty {
            Section(language.text("내가 만든 분류", "My categories")) {
                ForEach(custom) { categoryButton($0, apply: apply) }
            }
        }
    }

    private func categoryButton(
        _ category: MapHomeSidebarMajorCategory,
        apply: @escaping (MapHomeSidebarMajorCategory) -> Void
    ) -> some View {
        Button { apply(category) } label: {
            Label {
                Text(category.localizedTitle(language))
            } icon: {
                if let icon = categoryIcon(category.stickmanAction) {
                    Image(uiImage: icon)
                } else {
                    Image(systemName: category.systemImage)
                }
            }
        }
    }

    /// 메뉴에 넣을 고양이 그림. 메뉴는 움직이는 뷰를 그리지 못해 한 장으로 구워 둔다.
    func categoryIcon(_ action: MapHomeStickmanAction) -> UIImage? {
        NLECategoryIcon.image(action, coat: model.selectedCatCoat)
    }
}

/// 분류 메뉴와 분류 추가 화면이 같은 고양이 그림을 쓰게 한 곳에서 굽는다.
@MainActor
enum NLECategoryIcon {
    private static var cache: [String: UIImage] = [:]

    static func image(_ action: MapHomeStickmanAction, coat: CatCoat) -> UIImage? {
        let key = "\(action.rawValue)|\(coat)"
        if let cached = cache[key] { return cached }
        let renderer = ImageRenderer(content:
            HwarangSceneView(
                scene: action.hwarangScene,
                sec: 0,
                width: 28 * 1.6,
                anchorHeight: 28,
                showsBackdrop: false,
                keepsBodySize: false
            )
            .frame(width: 28, height: 28)
        )
        renderer.scale = 3
        let image = renderer.uiImage?.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }
}
