import SwiftUI
import UIKit

/// 넓은 화면(아이패드, 펼친 듀오)의 지도 홈 배치. 기기 이름이 아니라 실제 폭으로 가른다.
enum MapHomeWideLayoutPolicy {
    /// 이 폭부터 넓은 배치를 쓴다. 듀오 바깥 화면(466pt)·아이패드 좁은 분할은 아이폰 배치 그대로다.
    static let minimumWidth: CGFloat = 600
    /// 하단 메뉴 폭. 일곱 단추가 아이폰(402pt)과 같은 간격으로 놓인다.
    static let actionBarWidth: CGFloat = 402
    /// 날짜 줄 폭. 아이폰 402pt 화면에서 펼쳤을 때와 같다.
    static let dateStripWidth: CGFloat = 332
    /// 재생 진행 바·검색창 최대 폭.
    static let topOverlayMaximumWidth: CGFloat = 402
    /// 왼쪽 패널 폭. 아래 하단 메뉴와 같아 한 열로 보인다.
    static let panelWidth: CGFloat = actionBarWidth
    /// 달력을 두 열로 펴는 패널 폭과, 그렇게 펴도 지도가 남는 화면 폭.
    static let calendarColumnsPanelWidth: CGFloat = 680
    static let calendarColumnsMinimumViewportWidth: CGFloat = 1050
    /// 패널 옆에 이만큼 남아야 지도를 줄인다. 분할 화면처럼 좁으면 패널을 지도 위에 띄운다.
    static let minimumMapWidthBesidePanel: CGFloat = 360
    /// 상단 버튼 줄(위 여백 12 + 높이 40) 바로 아래.
    static let panelTopInset: CGFloat = 60
    /// 상단 줄 좌우 여백, 왼쪽 위 버튼 세 개(40pt, 간격 8pt) 폭, 날짜 줄과 배지 사이 간격.
    static let topRowInset: CGFloat = 10
    static let topLeftControlsWidth: CGFloat = 136
    static let dateStripBadgeGap: CGFloat = 6
    /// 메뉴를 다 펼치지 않은 한 열의 높이(권한 카드 제외)와 권한 카드 높이. `testMenuFits…`가 실제 화면으로 잠근다.
    static let menuSingleColumnHeight: CGFloat = 900
    static let menuPermissionCardHeight: CGFloat = 200
    /// 두 열 메뉴의 폭. 사이드바(패널 오른쪽 약 140pt)를 가리지 않는 안에서 680pt까지, 480pt보다 좁으면 한 열로 둔다.
    static let menuColumnsMaximumWidth: CGFloat = 680
    static let menuColumnsMinimumWidth: CGFloat = 480
    static let menuCompactRowsMaximumHeight: CGFloat = 760
    static let sidebarReservedWidth: CGFloat = 140
    /// 클립 편집을 두 열로 펴는 폭과 오른쪽 열 폭. 도구 여섯 개가 아이폰과 같은 간격으로 놓인다.
    static let clipColumnsMinimumWidth: CGFloat = 760
    static let clipInspectorWidth: CGFloat = 402

    static func isWide(viewportWidth: CGFloat) -> Bool {
        viewportWidth >= minimumWidth
    }

    /// 하단 메뉴 폭. 넓은 화면이 아니면 nil(가로 전체).
    static func actionBarWidth(viewportWidth: CGFloat) -> CGFloat? {
        isWide(viewportWidth: viewportWidth) ? actionBarWidth : nil
    }

    /// 사이드바가 아래쪽에서 비워 둘 높이. 넓은 화면은 하단 메뉴가 왼쪽에 있어 비울 것이 없다.
    static func sidebarBottomReserve(viewportWidth: CGFloat, actionBarHeight: CGFloat) -> CGFloat {
        isWide(viewportWidth: viewportWidth) ? 0 : actionBarHeight
    }

    /// 날짜 줄 최대 폭. 넓은 화면이 아니면 nil(남은 폭 전부).
    static func dateStripMaximumWidth(viewportWidth: CGFloat) -> CGFloat? {
        isWide(viewportWidth: viewportWidth) ? dateStripWidth : nil
    }

    /// 펼친 날짜 줄이 왼쪽 위 버튼(검색·메모·일정)에 닿는지. 날짜 줄은 오른쪽 날짜 배지에 붙어 왼쪽으로 펴진다.
    static func dateStripOverlapsTopLeftControls(viewportWidth: CGFloat) -> Bool {
        guard let stripWidth = dateStripMaximumWidth(viewportWidth: viewportWidth) else { return true }
        let stripMinX = viewportWidth - topRowInset - timeRailWidth(viewportWidth: viewportWidth) - dateStripBadgeGap - stripWidth
        return stripMinX < topRowInset + topLeftControlsWidth
    }

    /// 상단 오버레이(재생 바·검색창) 최대 폭. 넓은 화면이 아니면 nil(제한 없음).
    static func topOverlayMaximumWidth(viewportWidth: CGFloat) -> CGFloat? {
        isWide(viewportWidth: viewportWidth) ? topOverlayMaximumWidth : nil
    }

    /// 검색창 폭 계산에 넘길 화면 폭.
    static func searchViewportWidth(_ viewportWidth: CGFloat) -> CGFloat {
        topOverlayMaximumWidth(viewportWidth: viewportWidth) ?? viewportWidth
    }

    static func usesCalendarColumns(viewportWidth: CGFloat) -> Bool {
        viewportWidth >= calendarColumnsMinimumViewportWidth
    }

    static func panelWidth(viewportWidth: CGFloat, kind: MapHomeWidePanelKind) -> CGFloat {
        switch kind {
        case .standard: panelWidth
        case .calendar: usesCalendarColumns(viewportWidth: viewportWidth) ? calendarColumnsPanelWidth : panelWidth
        case .columns(let width): width
        }
    }

    /// 지도 왼쪽을 비울 폭. 패널이 없거나 남는 폭이 모자라면 0이다.
    static func mapLeadingInset(viewportWidth: CGFloat, openPanel: MapHomeWidePanelKind?) -> CGFloat {
        guard let openPanel, isWide(viewportWidth: viewportWidth) else { return 0 }
        let inset = panelWidth(viewportWidth: viewportWidth, kind: openPanel) + MapHomeBottomBarMetrics.edgeMargin * 2
        return viewportWidth - inset >= minimumMapWidthBesidePanel ? inset : 0
    }

    /// 두 열로 펴도 왼쪽 열이 높이에 모자라는 낮은 가로 화면(듀오 안쪽)은 메뉴 줄 간격을 줄인다.
    static func menuUsesCompactRows(viewportSize: CGSize, kind: MapHomeWidePanelKind) -> Bool {
        kind.columns > 1 && viewportSize.height < menuCompactRowsMaximumHeight
    }

    /// 메인 메뉴 자리. 세로는 한 열. 가로는 한 열이 높이에 안 들어가면 옆으로 펴서 스크롤 없이 보인다.
    static func menuPanelKind(viewportSize: CGSize, hasPermissionCard: Bool) -> MapHomeWidePanelKind {
        guard isWide(viewportWidth: viewportSize.width), viewportSize.width > viewportSize.height else { return .standard }
        let available = viewportSize.height - panelTopInset - MapHomeBottomBarMetrics.reservedHeight - 8
        let needed = menuSingleColumnHeight + (hasPermissionCard ? menuPermissionCardHeight : 0)
        guard available < needed else { return .standard }
        let width = min(menuColumnsMaximumWidth, viewportSize.width - MapHomeBottomBarMetrics.edgeMargin - sidebarReservedWidth)
        return width >= menuColumnsMinimumWidth ? .columns(width: width) : .standard
    }

    /// 시간 레일 폭. 넓은 화면은 눈금과 잡는 자리를 조금 넓혀 큰 화면 비율에 맞춘다.
    static func timeRailWidth(viewportWidth: CGFloat) -> CGFloat {
        isWide(viewportWidth: viewportWidth) ? 52 : 44
    }

    static func usesClipColumns(width: CGFloat) -> Bool {
        width >= clipColumnsMinimumWidth
    }
}

enum MapHomeWidePanelKind: Equatable {
    case standard
    case calendar
    case columns(width: CGFloat)

    var columns: Int {
        if case .columns = self { 2 } else { 1 }
    }
}

extension EnvironmentValues {
    /// 시트가 아니라 넓은 화면의 왼쪽 패널 안에 놓였는지.
    @Entry var mapHomeIsWidePanel = false
    @Entry var mapHomeWidePanelColumns = 1
    @Entry var mapHomeMenuIsCompact = false
}

/// 좁은 폭에서는 시트, 넓은 폭에서는 하단 메뉴 위 왼쪽 패널로 띄운다. 폭이 갈려도 열림 상태는 이어진다.
private struct MapHomeWidePanelPresenter<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let kind: MapHomeWidePanelKind
    let title: String?
    let viewportWidth: CGFloat
    let language: MapHomeLanguage
    @ViewBuilder let panel: () -> Panel

    private var isWide: Bool { MapHomeWideLayoutPolicy.isWide(viewportWidth: viewportWidth) }

    func body(content: Content) -> some View {
        let wide = isWide
        content
            .sheet(isPresented: Binding(
                get: { isPresented && !wide },
                set: { if !wide { isPresented = $0 } }
            ), content: panel)
            .overlay {
                if isPresented, wide {
                    panelBody
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: isPresented && wide)
    }

    private var panelBody: some View {
        VStack(spacing: 0) {
            if let title {
                HStack {
                    Text(title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(17)), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Spacer()
                    closeButton
                }
                .padding(.leading, 20)
                .padding(.trailing, 8)
                .padding(.top, 8)
            }
            panel()
                .environment(\.mapHomeIsWidePanel, true)
                .environment(\.mapHomeWidePanelColumns, kind == .calendar && MapHomeWideLayoutPolicy.usesCalendarColumns(viewportWidth: viewportWidth) ? 2 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if title == nil {
                closeButton.padding(8)
            }
        }
        .mapHomeWidePanelFrame(viewportWidth: viewportWidth, kind: kind)
    }

    private var closeButton: some View {
        Button { isPresented = false } label: {
            Image(systemName: "xmark")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                .foregroundStyle(Color.tpInk.opacity(0.7))
                .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                .mapHomeGlass(in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("패널 닫기", "Close panel"))
    }
}

/// 넓은 패널은 두 묶음을 나란히, 그 밖에는 위아래로 놓는다.
struct MapHomeWidePanelColumns<Leading: View, Trailing: View>: View {
    let columns: Int
    var spacing: CGFloat = 0
    var alignment: HorizontalAlignment = .center
    var trailingTopInset: CGFloat = 6
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if columns > 1 {
            HStack(alignment: .top, spacing: spacing) {
                VStack(alignment: alignment, spacing: 0) { leading }
                    .frame(maxWidth: .infinity)
                VStack(alignment: alignment, spacing: 0) { trailing }
                    .frame(maxWidth: .infinity)
                    .padding(.top, trailingTopInset)
            }
        } else {
            VStack(alignment: alignment, spacing: 0) {
                leading
                trailing
            }
        }
    }
}

/// 패널 안에서 한 단계 들어간 화면. 뒤로 단추로 돌아온다.
struct MapHomeWidePanelPage<Content: View>: View {
    let language: MapHomeLanguage
    let onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                    .foregroundStyle(Color.tpInk.opacity(0.7))
                    .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                    .mapHomeGlass(in: Circle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(language.text("뒤로", "Back"))
            content
        }
        .background(Color.tpBackground)
    }
}

extension MapHomeNLEClipEditor {
    /// 넓은 화면: 왼쪽에 세로 타임라인, 오른쪽에 머리말·선택 요약·도구를 모은다.
    func wideLayout(size: CGSize, headerHeight: CGFloat, spacing: CGFloat) -> some View {
        let inspectorWidth = MapHomeWideLayoutPolicy.clipInspectorWidth
        let railWidth = size.width - inspectorWidth
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                laneHeader(width: railWidth)
                    .frame(width: railWidth, height: headerHeight)
                verticalRail
                    .frame(width: railWidth, height: size.height - headerHeight - 4)
            }
            .frame(width: railWidth, alignment: .leading)
            .clipped()
            VStack(spacing: spacing) {
                header
                selectionSummary
                toolbar
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.railBleed)
            .frame(width: inspectorWidth)
        }
    }
}

/// 넓은 폭에서 왼쪽 자리를 함께 쓰는 것들은 하나만 열어 둔다.
private struct MapHomeWidePanelsExclusive: ViewModifier {
    let viewportWidth: CGFloat
    let panels: [Binding<Bool>]

    func body(content: Content) -> some View {
        content.onChange(of: panels.map(\.wrappedValue)) { old, new in
            guard MapHomeWideLayoutPolicy.isWide(viewportWidth: viewportWidth),
                  let opened = new.indices.first(where: { new[$0] && !old[$0] })
            else { return }
            for index in panels.indices where index != opened && new[index] {
                panels[index].wrappedValue = false
            }
        }
    }
}

/// 화면 방향 규칙. 화면 짧은 변이 넓으면(아이패드, 듀오 안쪽) 가로·세로, 아니면(일반 아이폰, 듀오 바깥) 세로만.
enum AppOrientationPolicy {
    static let rotatableShortSide: CGFloat = 600

    /// Info.plist 값과 교집합이 적용되므로 폰에서 `.all`이어도 거꾸로 세운 세로는 나오지 않는다.
    static func mask(screenSize: CGSize) -> UIInterfaceOrientationMask {
        min(screenSize.width, screenSize.height) >= rotatableShortSide ? .all : .portrait
    }
}

extension View {
    func mapHomeWidePanel<Panel: View>(
        isPresented: Binding<Bool>,
        kind: MapHomeWidePanelKind = .standard,
        title: String? = nil,
        viewportWidth: CGFloat,
        language: MapHomeLanguage,
        @ViewBuilder content: @escaping () -> Panel
    ) -> some View {
        modifier(MapHomeWidePanelPresenter(
            isPresented: isPresented,
            kind: kind,
            title: title,
            viewportWidth: viewportWidth,
            language: language,
            panel: content
        ))
    }

    func mapHomeWidePanelsExclusive(viewportWidth: CGFloat, _ panels: [Binding<Bool>]) -> some View {
        modifier(MapHomeWidePanelsExclusive(viewportWidth: viewportWidth, panels: panels))
    }

    /// 왼쪽 패널 자리: 상단 버튼 줄 아래부터 하단 메뉴 위까지. 패널 밖의 탭은 지도로 그대로 간다.
    func mapHomeWidePanelFrame(viewportWidth: CGFloat, kind: MapHomeWidePanelKind) -> some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return frame(width: MapHomeWideLayoutPolicy.panelWidth(viewportWidth: viewportWidth, kind: kind))
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.tpBackground)
            .clipShape(shape)
            .overlay { shape.stroke(Color.tpLine.opacity(0.6), lineWidth: 0.8) }
            .shadow(color: Color.black.opacity(0.14), radius: 16, x: 4, y: 0)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mapHomeWidePanel")
            .padding(.top, MapHomeWideLayoutPolicy.panelTopInset)
            .padding(.bottom, MapHomeBottomBarMetrics.reservedHeight + 8)
            .padding(.leading, MapHomeBottomBarMetrics.edgeMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 시험용: `-debugViewportWidth 600`이면 분할 화면 폭으로 그린다.
    @ViewBuilder
    func mapHomeDebugViewportWidth() -> some View {
        #if DEBUG
        let width = UserDefaults.standard.double(forKey: "debugViewportWidth")
        if width > 0 {
            let height = UserDefaults.standard.double(forKey: "debugViewportHeight")
            if height > 0 {
                frame(width: width, height: height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.black)
            } else {
                frame(width: width).frame(maxWidth: .infinity, alignment: .leading).background(Color.black)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// 하단 메뉴 알약 자리. 넓은 화면은 왼쪽 아래에 폭을 정해 두고, 좁은 폭은 좌우 여백까지 채운다.
    func mapHomeWideActionBar(viewportWidth: CGFloat) -> some View {
        frame(width: MapHomeWideLayoutPolicy.actionBarWidth(viewportWidth: viewportWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MapHomeBottomBarMetrics.edgeMargin)
            .padding(.bottom, MapHomeBottomBarMetrics.edgeMargin)
    }

    /// 넓은 화면에서 검색창 줄을 아이폰 폭으로 왼쪽에 둔다.
    func mapHomeWideTopOverlay(viewportWidth: CGFloat) -> some View {
        frame(maxWidth: MapHomeWideLayoutPolicy.topOverlayMaximumWidth(viewportWidth: viewportWidth))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 화면(접힘·펼침)이 바뀌면 허용 방향을 다시 묻게 한다.
    func refreshesSupportedOrientations() -> some View {
        onGeometryChange(for: CGSize.self, of: { $0.size }) { _ in
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// 메뉴 한 줄의 위아래 여백. 낮은 가로 화면에서도 줄 높이 44pt를 지킨다.
struct MapHomeMenuRowPadding: ViewModifier {
    @Environment(\.mapHomeMenuIsCompact) private var isCompact

    func body(content: Content) -> some View {
        content.padding(.vertical, isCompact ? 6 : 9)
    }
}

struct MapHomeMenuGroupLabelPadding: ViewModifier {
    @Environment(\.mapHomeMenuIsCompact) private var isCompact

    func body(content: Content) -> some View {
        content.padding(.top, isCompact ? 8 : 16)
    }
}
