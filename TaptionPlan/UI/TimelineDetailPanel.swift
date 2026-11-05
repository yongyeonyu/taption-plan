import SwiftUI
import UIKit
import MapKit

enum TimelineDetailSection: String, CaseIterable, Identifiable {
    case schedule = "일정"
    case location = "위치"
    case movement = "이동"
    case sleep = "수면"
    case activity = "활동"
    case appUsage = "어플"
    case weather = "날씨"
    case routine = "루틴"
    case action = "액션·메모"
    case photo = "사진"
    case memo = "메모"
    case event = "이벤트"
    case map = "지도"

    var id: Self { self }

    /// 시간표 줄과 같은 기호를 쓴다. 표를 두 벌 두면 한쪽만 바뀐다.
    var rowKind: TimelineRowKind? {
        switch self {
        case .schedule: .calendar
        case .location: .location
        case .movement: .movement
        case .sleep: .sleep
        case .activity: .activity
        case .appUsage: .appUsage
        case .weather: .weather
        case .photo: .photo
        case .memo: .memo
        case .routine, .action, .event, .map: nil
        }
    }

    var systemImage: String {
        if let rowKind { return rowKind.systemImage }
        switch self {
        case .routine: return "repeat.circle"
        case .action: return "checklist.checked"
        case .event: return "sparkles"
        case .map: return "map"
        default: return "circle"
        }
    }

    static let defaultOrder: [Self] = [
        .schedule,
        .location,
        .movement,
        .sleep,
        .activity,
        .appUsage,
        .weather,
        .photo,
        .memo,
        .map,
        .routine,
        .action,
        .event,
    ]
}

struct TimelineDetailPanel: View {
    @Bindable var model: AppModel

    let selection: TimelineSelection?

    let playheadDate: Date?

    @Binding var panelHeight: CGFloat

    let maxHeight: CGFloat

    @Binding var section: TimelineDetailSection

    let highlightedSection: TimelineDetailSection?

    @Binding var selectedPhotoCluster: PhotoCluster?

    let routeReadings: [SensorReading]

    let onActualDeleted: (UUID) -> Void

    let onRouteSelection: (TimelineSelection) -> Void

    @State var mapPosition: MapCameraPosition = .automatic

    @State var routeMapViewportSize = CGSize.zero

    // 지도에서 선을 골라내려면 지금 보이는 범위를 알아야 한다. 카메라가
    // 멈출 때만 받아 두어 프레임마다 값이 바뀌지 않게 한다.
    @State var visibleMapRegion: MKCoordinateRegion?

    @State var selectedPhotoIndex = 0

    @State var pendingActualDeletionID: UUID?

    @State var showsGoalLinkSheet = false

    @State var showsRecordLinkSheet = false

    @State var showsActionLinkSheet = false

    @State var actionPlanForRoutineLink: PlanRecord?

    @State var lastMapFocusCoordinate: CLLocationCoordinate2D?

    // Mutating the gate itself does not invalidate the detail view, unlike a
    // rapidly changing @State timestamp on every live sensor callback.
    @State var mapFitGate = TimelineMapFitGate()

    @State var photoClusterCache = TimelinePhotoClusterCache()

    // Route geometry is requested by several detail cards and by MapKit in
    // the same render pass. Cache the filtered segments and coordinate
    // polylines so a live playhead update does not rescan every reading for
    // each consumer.
    @State var routePresentationCache =
        TimelineRoutePresentationCache()

    @State var placeIndexCache = TimelinePlaceIndexCache()

    @State var planIndexCache = TimelinePlanIndexCache()

    // The same filtered detail collections are consumed by both section
    // visibility and the card body. Reuse them for a playhead tick instead
    // of rescanning plans, actuals, places, and calendar events twice.
    @State var detailDataCache = TimelineDetailDataCache()

    @State var panelDragStartHeight: CGFloat?

    @State var lastPanelResizeRenderUptime: TimeInterval = 0

    var body: some View {
        VStack(spacing: 0) {
            panelResizeHandle
            // Keep the selected item's icon visible while the playhead moves.
            // Empty intervals still have no header because activeSelection is
            // nil, so no stale routine title is invented.
            if activeSelection != nil {
                detailContextHeader
            }
            if playheadDate == nil,
               !TaptionProductScope.automaticLoggingOnly,
               let selection,
               selection.recordNodeID != nil,
               selection.actualID == nil,
               selection.categoryID != "location",
               selection.categoryID != "movement" {
                recordLinkControl(selection)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 9) {
                        ForEach(availableDetailSections) { item in
                            detailCard(for: item)
                                .id(item)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    // 하단 탭 막대는 화면 위에 떠 있어 안전 영역을 넓혀 주지
                    // 않는다. 마지막 카드가 막대 뒤로 숨지 않게 비워 둔다.
                    .padding(.bottom, DraftBottomBarMetrics.contentInset)
                }
                .scrollDismissesKeyboard(.interactively)
                // 콘텐츠가 화면보다 짧거나 마지막 카드까지 도달하면
                // 아래쪽 고무줄 반동을 만들지 않는다.
                .scrollBounceBehavior(.basedOnSize)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .top
                )
                .background(Color.tpBackground)
                .onChange(of: section) { _, newSection in
                    withAnimation(.easeInOut(duration: 0.24)) {
                        proxy.scrollTo(newSection, anchor: .top)
                    }
                }
            }
        }
        .background(Color.tpBackground)
        .clipped()
        .overlay(alignment: .top) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
        .onChange(of: selection) { _, _ in
            ensureVisibleDetailSection()
            fitMapToRoutes(force: true)
            selectedPhotoIndex = 0
        }
        .onChange(of: playheadDate) { _, _ in
            // Playhead detail is delivered at 20 Hz, but MapKit does not
            // need a camera transaction for every delivered tick. Keep the
            // location marker responsive while limiting expensive region
            // updates to a 15 Hz presentation budget.
            fitMapToRoutes()
        }
        .onChange(of: routeReadingsSignature) { _, _ in
            fitMapToRoutes()
        }
        .onChange(of: model.latestSensorReading?.timestamp) { _, _ in
            // A fresh GPS fix is the source of truth for the idle map center.
            fitMapToRoutes()
        }
        .onChange(of: model.liveRouteState.lastUpdatedAt) { _, _ in
            // Live tracking can update before the archived readings refresh.
            fitMapToRoutes()
        }
        .onChange(of: selectedPhotoCluster?.id) { _, _ in
            selectedPhotoIndex = 0
        }
        .task {
            ensureVisibleDetailSection()
            fitMapToRoutes(force: true)
        }
        .confirmationDialog(
            "이 실제 기록을 삭제할까요?",
            isPresented: Binding(
                get: { pendingActualDeletionID != nil },
                set: { if !$0 { pendingActualDeletionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("실제 기록 삭제", role: .destructive) {
                guard let actualID = pendingActualDeletionID else { return }
                pendingActualDeletionID = nil
                Task {
                    await model.deleteActual(actualID)
                    onActualDeleted(actualID)
                }
            }
            Button("취소", role: .cancel) {
                pendingActualDeletionID = nil
            }
        } message: {
            Text("이 기록만 삭제되며 연결된 계획은 그대로 유지됩니다.")
        }
        .sheet(isPresented: $showsGoalLinkSheet) {
            if let actual = selectedActual {
                GoalActualLinkSheet(model: model, actual: actual)
            }
        }
        .sheet(isPresented: $showsRecordLinkSheet) {
            if let selection,
               let sourceNodeID = selection.recordNodeID {
                RecordNodeLinkSheet(
                    model: model,
                    sourceNodeID: sourceNodeID,
                    sourceTitle: selection.title
                )
            }
        }
        .sheet(isPresented: $showsActionLinkSheet) {
            if let routine = focusedRoutineForDetail {
                GoalActionLinkSheet(model: model, goal: routine)
            }
        }
        .sheet(item: $actionPlanForRoutineLink) { action in
            RoutineActionLinkSheet(model: model, action: action)
        }
    }

    let automaticDetailCategoryIDs: Set<String> = [
        "location",
        "movement",
        "sleep",
        "activity",
        "appUsage",
    ]

    /// 달력을 고르는 값은 늘 같다. 재생 머리가 움직이는 동안 카드마다 이
    /// 달력을 새로 세우지 않게 한 번만 만들어 둔다.
    static let periodEngine = TimelineAggregationEngine()

    var routePresentationCacheKey:
        TimelineRoutePresentationCache.Key {
        TimelineRoutePresentationCache.Key(
            timelineRevision: model.timelineRevision,
            readingsCount: routeReadings.count,
            firstReadingID: routeReadings.first?.id,
            lastReadingID: routeReadings.last?.id,
            firstReadingTimestamp: routeReadings.first?.timestamp,
            lastReadingTimestamp: routeReadings.last?.timestamp,
            liveRouteUpdatedAt: model.liveRouteState.lastUpdatedAt
        )
    }

    var routeMapHeight: CGFloat { 216 }
}

/// 이 항목에 남아 있는 메모를 보여 주기만 한다. 입력은 시간표의 메모 줄
/// 하나로 모았다. 항목마다 입력칸을 두던 시절에는 메모를 남기려면 먼저 맞는
/// 줄과 기록을 찾아 눌러야 했고, 어떤 항목에서는 아예 열리지 않았다.
struct DetailMemoList: View {
    @Bindable var model: AppModel
    let selection: TimelineSelection?
    let section: TimelineDetailSection
    /// 이미 골라 둔 메모를 그대로 편다. 비워 두면 고른 항목에 달린 메모를
    /// 스스로 찾는다.
    var memos: [ActionMemo]?
    /// 누를 수 있는 목록인지. 메모 카드에서만 쓰고, 항목에 딸린 목록은
    /// 보여 주기만 한다.
    var onSelect: ((ActionMemo) -> Void)?

    var body: some View {
        let items = memos ?? savedMemos
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
                ForEach(items) { memo in
                    if let onSelect {
                        Button {
                            onSelect(memo)
                        } label: {
                            memoRow(memo)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(memo.text) 메모 열기"
                        )
                    } else {
                        memoRow(memo)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                Color.tpBackground,
                in: RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TaptionRadius.small, style: .continuous)
                    .stroke(Color.tpLine.opacity(0.7), lineWidth: 0.5)
            }
            .accessibilityLabel(
                section == .memo ? "메모 목록" : "\(section.rawValue) 메모"
            )
        }
    }

    private func memoRow(_ memo: ActionMemo) -> some View {
        HStack(alignment: .top, spacing: TaptionSpacing.compact) {
            Image(systemName: TimelineRowKind.memo.systemImage)
                .font(.taption(size: 8, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(memo.text)
                    .font(.taption(size: 8.5))
                    .foregroundStyle(Color.tpInk)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    memo.occurredAt.formatted(
                        date: .omitted,
                        time: .shortened
                    )
                )
                .font(.taption(size: 7))
                .foregroundStyle(Color.tpSecondary)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            Color.white.opacity(0.75),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private var savedMemos: [ActionMemo] {
        guard let selection else {
            return []
        }
        if let targetID = selection.memoTargetID {
            let targetMemos = model.memos(forTargetID: targetID)
            // Keep old plan-only notes visible after migrating a plan to the
            // stable target key, without duplicating newly keyed entries.
            guard targetID.hasPrefix("plan."), let planID = selection.planID else {
                return targetMemos
            }
            return (targetMemos + model.memos(for: planID))
                .reduce(into: [UUID: ActionMemo]()) { result, memo in
                    result[memo.id] = memo
                }
                .values
                .sorted { $0.createdAt < $1.createdAt }
        }
        return model.memos(
            forCategoryID: selection.categoryID,
            on: selection.span.start
        )
    }
}

struct PhotoAssetThumbnail: View {
    @Bindable var model: AppModel
    let localIdentifier: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [.tpPhoto, .tpPhotoDark.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "photo")
                        .accessibilityHidden(true)
                        .font(.taption(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .clipped()
        .task(id: localIdentifier) {
            guard image == nil else { return }
            guard let data = try? await model.photoThumbnailData(
                localIdentifier: localIdentifier,
                size: CGSize(width: 120, height: 120)
            ) else {
                return
            }
            image = UIImage(data: data)
        }
    }
}
