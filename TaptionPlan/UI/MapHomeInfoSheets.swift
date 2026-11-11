import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

/// 지도 위 마커를 탭했을 때 그 의미를 설명하는 상세 창의 종류.
enum MapHomeMarkerInfoKind: Identifiable, Hashable {
    case cat(MapHomeStickmanAction)
    case pawprint
    case landmark(MapHomeLocationDestination)
    case flag
    case expedition(distanceText: String, placeCount: Int, activityKinds: Int)

    var id: String {
        switch self {
        case .cat(let a): "cat-\(a.rawValue)"
        case .pawprint: "pawprint"
        case .landmark(let d): "landmark-\(d.rawValue)"
        case .flag: "flag"
        case .expedition(let d, let p, let a): "expedition-\(d)-\(p)-\(a)"
        }
    }
}

/// 등록지점의 범위를 지도 위 원으로 보여 주고 슬라이더로 바꾼다. 저장하면 그 지점의 반경이 바뀐다.
/// 등록지점 이름 변경. 저장하면 지도·목록·랜드마크 시트에 같은 이름이 나온다.
struct MapHomePlaceNameEditor: View {
    let model: AppModel
    let placeID: UUID
    let language: MapHomeLanguage
    @State private var name = ""

    private var place: FrequentPlace? {
        model.settings.frequentPlaces.first { $0.id == placeID }
    }

    var body: some View {
        if let place {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 10) {
                Text(language.text("이름", "Name"))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                TextField(language.text("장소 이름", "Place name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                Button(language.text("이름 저장", "Save name")) {
                    model.updateFrequentPlaceDetails(
                        place.id,
                        name: trimmed,
                        radiusMeters: place.radiusMeters,
                        minimumDwellMinutes: place.minimumDwellMinutes,
                        isAutomaticRecordingEnabled: place.isAutomaticRecordingEnabled
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tpAccent)
                .disabled(trimmed.isEmpty || trimmed == place.name)
                .frame(maxWidth: .infinity)
            }
            .onAppear { name = place.name }
        }
    }
}

struct MapHomePlaceRangeEditor: View {
    static let showsRangeKey = "mapHomeShowsPlaceRanges"

    let model: AppModel
    let placeID: UUID
    let language: MapHomeLanguage
    @State private var radiusMeters: Double = 120
    @AppStorage(showsRangeKey) private var showsRanges = true

    private var place: FrequentPlace? {
        model.settings.frequentPlaces.first { $0.id == placeID }
    }

    var body: some View {
        if let place, let point = place.point {
            let center = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(language.text("범위 지정", "Range"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    Spacer()
                    Toggle(language.text("지도에 범위 표시", "Show on map"), isOn: $showsRanges)
                        .labelsHidden()
                        .tint(Color.tpAccent)
                    Text(language.text("지도 표시", "Map"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                }
                MapHomePlaceRangeMap(center: center, radiusMeters: radiusMeters, tint: UIColor(Color.tpAccent))
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Text(language.text("반경", "Radius"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    Spacer()
                    Text("\(Int(radiusMeters.rounded()))m")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                }
                Slider(value: $radiusMeters, in: 30...500, step: 10)
                    .tint(Color.tpAccent)
                Button(language.text("범위 저장", "Save range")) {
                    model.updateFrequentPlaceDetails(
                        place.id,
                        name: place.name,
                        radiusMeters: radiusMeters,
                        minimumDwellMinutes: place.minimumDwellMinutes,
                        isAutomaticRecordingEnabled: place.isAutomaticRecordingEnabled
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.tpAccent)
                .frame(maxWidth: .infinity)
            }
            .onAppear { radiusMeters = place.radiusMeters }
        }
    }
}

struct MapHomeMarkerInfoSheet: View {
    let kind: MapHomeMarkerInfoKind
    let language: MapHomeLanguage
    /// 등록지점(집·회사 등)이면 여기서 이름을 바꾸고 범위(반경)를 지도 원으로 고칠 수 있다.
    var model: AppModel? = nil
    var placeID: UUID? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(26)), weight: .bold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 52, height: 52)
                        .background(Color.tpAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(title)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                        .foregroundStyle(Color.tpInk)
                    Spacer()
                }
                Text(detail)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let model, let placeID {
                    MapHomePlaceNameEditor(model: model, placeID: placeID, language: language)
                    MapHomePlaceRangeEditor(model: model, placeID: placeID, language: language)
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpBackground)
    }

    private var symbol: String {
        switch kind {
        case .cat: "pawprint.circle.fill"
        case .pawprint: "pawprint.fill"
        case .landmark(let d): d.rpgSystemImage
        case .flag: "flag.fill"
        case .expedition: "scroll.fill"
        }
    }

    private var title: String {
        switch kind {
        case .cat(let a): language.text("화랑이 · \(a.title)", "Hwarang · \(a.title)")
        case .pawprint: language.text("발자국 흔적", "Pawprint Trail")
        case .landmark(let d): language.text("랜드마크 · \(d.koreanName)", "Landmark · \(d.englishName)")
        case .flag: language.text("점령 깃발", "Conquered Flag")
        case .expedition: language.text("오늘의 탐험 일지", "Today's Expedition Log")
        }
    }

    private var detail: String {
        switch kind {
        case .cat:
            language.text(
                "탐험가 고양이 화랑이입니다. 지금 내 위치와 활동을 나타내며, 걷기·뛰기·수면·업무 등 활동에 따라 동작이 바뀌고, 이동 속도가 빠를수록 더 다이나믹하게 질주합니다.",
                "Your explorer cat showing your current location and activity. Its motion changes with what you're doing, and the faster you move the more dynamically it dashes."
            )
        case .pawprint:
            language.text(
                "오늘 이동한 경로에 찍힌 고양이 발자국입니다. 발자국을 따라가면 하루 동안 탐험한 길을 되짚어볼 수 있어요.",
                "Cat pawprints stamped along today's route. Follow them to retrace the path you explored."
            )
        case .landmark:
            language.text(
                "자주 방문하는 장소가 판타지 랜드마크로 표시됩니다. 집=오두막, 회사=길드 성, 학교=지식의 탑처럼 각 장소가 고유한 건물로 나타납니다. Lv 배지는 층수입니다.",
                "Frequently visited places appear as fantasy landmarks — home as a lodge, work as a guild castle, school as a tower. The Lv badge is the floor."
            )
        case .flag:
            language.text(
                "방문해서 '점령'한 장소에 꽂히는 깃발입니다. 새로운 곳을 방문할수록 더 많은 깃발이 모입니다.",
                "A flag planted on a place you've visited and 'conquered'. Visit new places to collect more."
            )
        case .expedition(let d, let p, let a):
            language.text(
                "오늘 화랑이의 탐험 기록입니다.\n\n🐾 이동 거리: \(d)\n🚩 방문 장소: \(p)곳\n🎖️ 활동 종류: \(a)종\n\n더 멀리 이동하고 새로운 장소를 방문할수록 탐험 기록이 늘어납니다.",
                "Hwarang's expedition log for today.\n\n🐾 Distance: \(d)\n🚩 Places: \(p)\n🎖️ Activities: \(a)\n\nTravel farther and visit new places to grow your log."
            )
        }
    }
}

/// 하루 요약 시트의 한 줄(대분류 하나). 세부 기록에서 파생한 값만 담는다.
struct MapHomeDaySummaryEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let systemImage: String
    let tint: Color
    let seconds: TimeInterval
    let ratio: Double
}

/// 지도에서 여는 하루 대분류 요약. 세부 활동은 건드리지 않고, 대분류별
/// 소요 시간과 비중만 막대로 보여준다.
/// 화랑이 위에 쌓는 카운터 한 줄(걸음·거리·업무·학습·취미·운동).
struct MapHomeCounterBadge: Identifiable {
    let kind: MapHomeCounterKind
    let text: String

    var id: String { kind.rawValue }
}

/// 하루 요약 맨 위에 보여 주는 집 성장 카드 값. 집 핀의 성장 값과 같은 출처다.
struct MapHomeGrowthCardInfo: Equatable {
    var level: Int
    var status: String
    var isQualifiedToday: Bool
    var streak: Int
    var pendingWeeklyRewards: Int
}

struct MapHomeDaySummarySheet: View {
    let date: Date
    let categories: [MapHomeDaySummaryEntry]
    let stepCount: Int?
    var travelDistances: [MapHomeDayTravelDistanceEntry] = []
    @Binding var growthData: Data
    let language: MapHomeLanguage
    var growthCard: MapHomeGrowthCardInfo? = nil
    /// 지도와 같은 집 그림(레벨·날씨·하늘)을 줄인 것(SUM1103A01).
    var homeArtwork: AnyView? = nil
    var salary: MapHomeSalaryPolicy.Live? = nil
    var memoCounts: (total: Int, map: Int) = (0, 0)
    /// 집 범위를 이 화면에서 바꿀 수 있도록 모델과 집 장소 id를 받는다.
    var model: AppModel? = nil
    var homePlaceID: UUID? = nil
    /// 시트 높이. 접힌 절반과 펼친 전체 두 단계뿐이다.
    @Binding var detent: PresentationDetent
    @State private var isGrowthPresented = false
    @State private var isGrowthInPanel = false
    @Environment(\.mapHomeIsWidePanel) private var isWidePanel
    private static let bottomPadding: CGFloat = 40

    /// 집 아이콘을 눌렀을 때 처음 올라오는 높이(화면 절반). 위로 펼치면 지금의 전체 화면이다.
    static var collapsedDetent: PresentationDetent {
        .fraction(MapHomeDaySummaryLayout.collapsedCoverage)
    }

    static let expandedDetent: PresentationDetent = .large

    private var isExpanded: Bool { detent == Self.expandedDetent }

    private var totalSeconds: TimeInterval {
        categories.reduce(0) { $0 + $1.seconds }
    }

    /// 오늘·이번 달 번 돈과 시급, 출퇴근까지 넣은 실질 시급.
    private func salaryCardView(_ salary: MapHomeSalaryPolicy.Live) -> some View {
        let today = MapHomeSalaryPolicy.earnings(workSeconds: salary.todayWorkSeconds, hourlyRate: salary.hourlyRate)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(language.text("오늘 번 돈", "Earned today"), systemImage: MapHomeCounterSalary.symbol(language: language))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text(MapHomeSalaryPolicy.wonText(today)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
            }
            HStack {
                Text(language.text("이번 달 예상 월급", "Expected this month"))
                    .foregroundStyle(Color.tpSecondary)
                Spacer()
                Text(MapHomeSalaryPolicy.wonText(salary.expectedMonthPay)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
            }
            if let month = salary.month {
                HStack {
                    Text(language.text("이번 달 \(Int(month.workSeconds / 3_600))시간 근무", "This month \(Int(month.workSeconds / 3_600)) h"))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Text(MapHomeSalaryPolicy.wonText(month.earnings)).font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                }
            }
            HStack {
                Text(language.text("시급 \(MapHomeSalaryPolicy.wonText(salary.hourlyRate))", "Hourly \(MapHomeSalaryPolicy.wonText(salary.hourlyRate))"))
                Spacer()
                if let effective = salary.month?.effectiveHourlyRate {
                    Text(language.text("출퇴근 포함 \(MapHomeSalaryPolicy.wonText(effective))", "With commute \(MapHomeSalaryPolicy.wonText(effective))"))
                        .foregroundStyle(Color.tpAccent)
                }
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold))
            Text(AppRegion.current.isOverseas
                 ? (salary.showsNet ? language.text("세후", "Net") : language.text("세전", "Gross"))
                 : (salary.showsNet ? language.text("세후 추정", "After-tax estimate") : language.text("세전 추정", "Pre-tax estimate")))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
        }
        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.9), lineWidth: 0.9)
        }
        .accessibilityElement(children: .combine)
    }

    private func growthCardView(_ card: MapHomeGrowthCardInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
        if let homeArtwork { homeArtwork }
        VStack(alignment: .leading, spacing: 8) {
            Text(MapHomeGrowthPolicy.homeTitle(level: card.level, language: language))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                .foregroundStyle(Color.tpInk)
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("Lv.\(card.level)")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.tpInk)
                Spacer(minLength: 8)
                Label(language.text("연속 \(card.streak)일", "\(card.streak)-day streak"), systemImage: "flame.fill")
                Label(language.text("보상 \(card.pendingWeeklyRewards)", "Rewards \(card.pendingWeeklyRewards)"), systemImage: "gift.fill")
            }
            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold))
            Text(card.status)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                .foregroundStyle(card.isQualifiedToday ? Color.tpAccent : Color.tpSecondary)
                .lineLimit(2)
            Capsule()
                .fill(card.isQualifiedToday ? Color.tpPastelMint : Color.tpLine.opacity(0.55))
                .frame(height: 4)
        }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.tpLine.opacity(0.9), lineWidth: 0.9)
        }
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            summaryContent
                .padding(22)
                .padding(.bottom, Self.bottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.tpBackground)
        // 처음에는 화면 절반, 위로 펼치면 전체 화면. 내용이 길면 그 안에서 스크롤한다.
        .presentationDetents(
            [Self.collapsedDetent, Self.expandedDetent],
            selection: $detent
        )
        .overlay {
            if isGrowthInPanel {
                MapHomeWidePanelPage(language: language, onBack: { isGrowthInPanel = false }) {
                    MapHomeGrowthSheet(growthData: $growthData, language: language)
                }
            }
        }
        .sheet(isPresented: $isGrowthPresented) {
            MapHomeGrowthSheet(
                growthData: $growthData,
                language: language
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// 위로 펼치기 아이콘. 접힌 시트에서 누르면 지금의 전체 화면이 되고, 펼친 상태에서는 다시 접는다.
    private var expandButton: some View {
        Button {
            detent = isExpanded ? Self.collapsedDetent : Self.expandedDetent
        } label: {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                .foregroundStyle(Color.tpAccent)
                .frame(width: 34, height: 34)
                .background(Color.tpAccent.opacity(0.10), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isExpanded
                ? language.text("하루 요약 접기", "Collapse day summary")
                : language.text("하루 요약 펼치기", "Expand day summary")
        )
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("하루 요약", "Day Summary"))
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(22)), weight: .bold))
                            .foregroundStyle(Color.tpInk)
                        Text(dateText)
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    Spacer(minLength: 8)
                    if !isWidePanel { expandButton }
                }
            }

            if let growthCard {
                // 레벨 상자를 누르면 우리 집 성장으로 간다.
                Button {
                    if isWidePanel { isGrowthInPanel = true } else { isGrowthPresented = true }
                } label: { growthCardView(growthCard) }
                .buttonStyle(.plain)
                .accessibilityHint(language.text("주간 보상과 집 성장 기록을 엽니다", "Opens weekly rewards and home growth"))
                .accessibilityIdentifier("daySummaryGrowthCard")
            }

            if let salary {
                salaryCardView(salary)
            }

            if memoCounts.total > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .foregroundStyle(Color.tpAccent)
                    Text(language.text("메모", "Memos"))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Text(language.text("\(memoCounts.total)개 · 지도 \(memoCounts.map)개", "\(memoCounts.total) · map \(memoCounts.map)"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                }
            }

            if let stepCount {
                HStack(spacing: 8) {
                    Image(systemName: "figure.walk")
                        .foregroundStyle(Color.tpAccent)
                    Text(language.text("걸음 수", "Steps"))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer()
                    Text(stepCount.formatted())
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundStyle(Color.tpInk)
                }
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
            }

            if categories.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.pie")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(30)), weight: .semibold))
                        .foregroundStyle(Color.tpSecondary)
                    Text(language.text("이 날의 기록이 아직 없습니다", "No records for this day yet"))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .medium))
                        .foregroundStyle(Color.tpSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Text(
                    language.text(
                        "총 \(DurationText.korean(totalSeconds)) 기록",
                        "\(DurationText.english(totalSeconds)) recorded"
                    )
                )
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)

                VStack(spacing: 12) {
                    ForEach(categories) { entry in
                        row(entry)
                    }
                }
            }

            if !travelDistances.isEmpty {
                travelDistanceSection
            }

            LedgerDaySummarySection(day: date, language: language)

            // 범위 지정은 요약 내용 아래에 둔다.
            if let model, let homePlaceID {
                MapHomePlaceRangeEditor(model: model, placeID: homePlaceID, language: language)
            }
        }
    }

    private var travelDistanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("이동 거리", "Distance by mode"))
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(travelDistances) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.mode.summarySystemImage)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                        .foregroundStyle(Color.tpAccent)
                        .frame(width: 24)
                    Text(language.runtimeText(entry.mode.summaryKoreanTitle, entry.mode.summaryEnglishTitle))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                    Spacer()
                    Text(MapHomeDayTravelSummary.distanceText(entry.meters))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.tpInk)
                }
            }
        }
    }

    private func row(_ entry: MapHomeDaySummaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: entry.systemImage)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                    .foregroundStyle(entry.tint)
                    .frame(width: 24)
                Text(entry.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Text("\(Int((entry.ratio * 100).rounded()))%")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(Color.tpInk)
                Text(DurationText.localized(entry.seconds, english: language == .english))
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(entry.tint.opacity(0.38))
                    Capsule()
                        .fill(entry.tint)
                        .frame(width: max(4, proxy.size.width * entry.ratio))
                }
            }
            .frame(height: 8)
        }
    }

    private var dateText: String {
        MapHomeDateText.string(
            from: date,
            format: language.dateTitleFormat,
            locale: language.locale
        )
    }
}
