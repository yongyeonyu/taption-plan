import CoreLocation
import MapKit
import Observation
import OSLog
import SwiftUI
import UIKit
import TaptionPlanCore

struct MapHomeGrowthSheet: View {
    @Binding var growthData: Data
    let language: MapHomeLanguage

    @State private var historyCache = MapHomeGrowthHistoryCache()
    @State private var showsTestTools = true
    @State private var showsAllAccessories = false

    private var history: MapHomeGrowthHistory {
        historyCache.history(for: growthData) ?? .initial(for: .now)
    }

    private var season: MapHomeGrowthSeason { history.season }
    private var placements: [MapHomeGrowthPlotPlacement] {
        season.landPlotPlacements ?? []
    }
    private var unplacedPlots: [String] {
        season.landPlots.filter { id in !placements.contains(where: { $0.plotID == id }) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    seasonProgress
                    weeklyRewardSection
                    if MapHomeLandFeature.isVisible { landSection }
                    accessorySection
                    archiveSection
                    if showsTestTools { testToolsSection }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .background(Color.tpBackground)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "house.and.flag.fill")
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .bold))
                .foregroundStyle(Color.tpAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("우리 집 성장", "Home growth"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(18)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(verbatim: "\(season.year) · Lv.\(season.level)")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
            .contentShape(Rectangle())
            // 제목을 1.5초 길게 누르면 시험 도구가 열린다.
            .onLongPressGesture(minimumDuration: 1.5) { showsTestTools.toggle() }
            Spacer()
            if season.pendingWeeklyRewards > 0 {
                Text(language.text("보상 \(season.pendingWeeklyRewards)", "Rewards \(season.pendingWeeklyRewards)"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.tpAccent.opacity(0.10), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color.tpSurface)
    }

    private var seasonProgress: some View {
        HStack(spacing: 14) {
            Image(MapHomeGrowthPolicy.artworkName(level: season.level))
                .resizable()
                .scaledToFit()
                .frame(width: 68, height: 68)
                .padding(8)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            VStack(alignment: .leading, spacing: 7) {
                Text(language.text("올해의 집", "This year's home"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                Text(language.text("Lv.\(season.level) / \(MapHomeGrowthPolicy.maximumLevel(year: season.year))", "Lv.\(season.level) / \(MapHomeGrowthPolicy.maximumLevel(year: season.year))"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                ProgressView(value: Double(season.level), total: Double(MapHomeGrowthPolicy.maximumLevel(year: season.year)))
                    .tint(Color.tpPastelMint)
                Text(language.text("연속 달성 \(season.streak)일", "\(season.streak)-day streak"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
            }
        }
        .padding(14)
        .background(Color.tpSurfaceCream, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var weeklyRewardSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("주간 진화 선택", "Weekly evolution"),
                subtitle: language.text("7일 연속 달성 보상 · 하나를 골라요", "7-day streak reward · choose one")
            )
            if MapHomeLandmarkCatalog.isCollectionComplete(season) {
                Text(language.text("액세서리 52개를 모두 모았어요.", "You collected all 52 accessories."))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else if season.pendingWeeklyRewards > 0 {
                ForEach(MapHomeLandmarkCatalog.weeklyChoices(for: season)) { candidate in
                    Button {
                        claim(candidate)
                    } label: {
                        HStack(spacing: 12) {
                            Group {
                                if UIImage(named: candidate.artworkName) != nil {
                                    Image(candidate.artworkName)
                                        .resizable()
                                        .scaledToFit()
                                } else {
                                    // 그림이 아직 없는 랜드마크는 무늬 심볼로 대신한다.
                                    Image(systemName: candidate.systemImage)
                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(20)), weight: .bold))
                                        .foregroundStyle(Color(hex: "#D94772"))
                                }
                            }
                            .frame(width: 44, height: 44)
                            .background(Color.tpAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(displayName(candidate))
                                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.tpInk)
                                Text("\(countryName(candidate.country)) · \(categoryName(candidate.category))")
                                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        .padding(11)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                let remaining = MapHomeGrowthPolicy.daysUntilNextWeeklyReward(streak: season.streak)
                Text(language.text("다음 보상까지 연속 \(remaining)일 남았어요.", "\(remaining) consecutive days until your next reward."))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var landSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("연결된 땅", "Connected land"),
                subtitle: language.text("보상을 받아 집 주변에 한 칸씩 이어 붙여요", "Place each earned plot beside your home or another plot")
            )
            if placements.isEmpty && unplacedPlots.isEmpty {
                Text(language.text("첫 주간 보상을 받으면 땅 조각이 생겨요.", "Your first weekly reward will add a land plot."))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                landGrid
                Text(language.text(
                    "지도에서 집 근처를 최대로 확대하면 이 땅이 집 주변에 그려지고, 점선 칸을 눌러 바로 이어 붙일 수 있어요.",
                    "Zoom all the way in near your home on the map to see this land and attach plots there."
                ))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
                if let next = unplacedPlots.first {
                    Text(language.text(
                        "붙이지 않은 땅 \(unplacedPlots.count)개 · 점선 칸을 눌러 이어 붙여요.",
                        "\(unplacedPlots.count) plots left · tap a dashed cell to attach."
                    ))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.tpSecondary)
                    Button {
                        place(next)
                    } label: {
                        Label(language.text("자동으로 붙이기", "Place automatically"), systemImage: "wand.and.stars")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.tpAccent)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 연결된 땅을 칸 모양 그대로 보여 준다. (0,0)은 집 자리. 붙일 땅이 남아 있으면 이을 수 있는 빈 칸이 점선으로 나온다.
    private var landGrid: some View {
        let candidates = unplacedPlots.isEmpty ? [] : MapHomeGrowthPolicy.placementCandidates(in: season)
        let xs = placements.map(\.x) + candidates.map(\.x)
        let ys = placements.map(\.y) + candidates.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let occupied = Dictionary(uniqueKeysWithValues: placements.map { ("\($0.x),\($0.y)", $0) })
        let candidateKeys = Set(candidates.map { "\($0.x),\($0.y)" })
        let cell: CGFloat = 42
        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(minY...maxY, id: \.self) { y in
                    HStack(spacing: 4) {
                        ForEach(minX...maxX, id: \.self) { x in
                            let key = "\(x),\(y)"
                            if occupied[key] != nil {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(Color.tpPastelMint.opacity(0.5))
                                    if x == 0 && y == 0 {
                                        Image(MapHomeGrowthPolicy.artworkName(level: season.level))
                                            .resizable()
                                            .scaledToFit()
                                            .padding(3)
                                    } else {
                                        Image(systemName: "leaf.fill")
                                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                                            .foregroundStyle(Color.tpAccent)
                                    }
                                }
                                .frame(width: cell, height: cell)
                                .accessibilityLabel(language.text("연결된 땅 조각", "Connected plot"))
                            } else if candidateKeys.contains(key), let plotID = unplacedPlots.first {
                                Button {
                                    placeLand(plotID, x: x, y: y)
                                } label: {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.tpAccent.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                                        .overlay {
                                            Image(systemName: "plus")
                                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                                                .foregroundStyle(Color.tpAccent)
                                        }
                                        .frame(width: cell, height: cell)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(language.text("여기에 땅 붙이기", "Attach land here"))
                            } else {
                                Color.clear.frame(width: cell, height: cell)
                            }
                        }
                    }
                }
            }
            .padding(2)
        }
    }

    private func placeLand(_ plotID: String, x: Int, y: Int) {
        var updated = history
        guard MapHomeGrowthPolicy.placeLandPlot(plotID, atX: x, y: y, in: &updated.season) else { return }
        save(updated)
    }

    private var accessorySection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text(
                    "화랑이 액세서리 \(season.accessories.count) / \(MapHomeLandmarkCatalog.candidates.count)",
                    "Hwarang accessories \(season.accessories.count) / \(MapHomeLandmarkCatalog.candidates.count)"
                ),
                subtitle: language.text("주간 진화 보상으로 모아 착용해요 · 현재 취득 / 전체", "Collect and equip from weekly rewards · owned / total")
            )
            Button {
                showsAllAccessories.toggle()
            } label: {
                Label(
                    language.text(showsAllAccessories ? "전체 도감 접기" : "전체 도감 보기", showsAllAccessories ? "Hide all" : "Show all"),
                    systemImage: showsAllAccessories ? "chevron.up" : "square.grid.3x3.fill"
                )
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .semibold, design: .rounded))
                .foregroundStyle(Color.tpAccent)
            }
            .buttonStyle(.plain)
            if showsAllAccessories { accessoryCollectionGrid }
            if season.accessories.isEmpty {
                Text(language.text("아직 모은 액세서리가 없어요.", "No accessories collected yet."))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(season.accessories, id: \.self) { accessoryID in
                    Button {
                        equip(accessoryID)
                    } label: {
                        HStack(spacing: 10) {
                            // 화랑이가 쓰는 모자. 옛 장식은 심볼로 보인다.
                            Group {
                                if let hat = MapHomeGrowthAccessoryCatalog.hatAssetName(for: accessoryID) {
                                    Image(hat).resizable().scaledToFit().padding(3)
                                } else {
                                    Image(systemName: MapHomeGrowthAccessoryCatalog.symbol(for: accessoryID) ?? "sparkles")
                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold))
                                        .foregroundStyle(Color(hex: "#D94772"))
                                }
                            }
                                .frame(width: 36, height: 36)
                                .background(Color.tpAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(accessoryName(accessoryID))
                                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.tpInk)
                                if let landmark = MapHomeGrowthAccessoryCatalog.landmark(for: accessoryID) {
                                    Text("\(countryName(landmark.country)) · \(categoryName(landmark.category))")
                                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                        .foregroundStyle(Color.tpSecondary)
                                }
                            }
                            Spacer()
                            if season.equippedAccessory == accessoryID {
                                Text(language.text("착용 중", "Equipped"))
                                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
                                    .foregroundStyle(Color.tpAccent)
                            }
                            // 지도에서 쓰는 화랑이 아이콘에 이 장식을 단 모습.
                            MapHomeStickmanMarker(action: .sleeping, equippedAccessoryID: accessoryID)
                                .frame(width: 36, height: 36)
                        }
                        .padding(12)
                        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// 전체 도감: 모은 장식은 색이 있고 눌러 착용, 못 모은 장식은 회색에 자물쇠.
    private var accessoryCollectionGrid: some View {
        let owned = Set(season.accessories)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
            ForEach(MapHomeLandmarkCatalog.candidates) { candidate in
                let isOwned = owned.contains(candidate.accessoryID)
                Button {
                    if isOwned { equip(candidate.accessoryID) }
                } label: {
                    VStack(spacing: 3) {
                        Group {
                            if isOwned, let hat = MapHomeGrowthAccessoryCatalog.hatAssetName(for: candidate.accessoryID) {
                                Image(hat).resizable().scaledToFit()
                            } else {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(15)), weight: .bold))
                                    .foregroundStyle(Color.tpSecondary.opacity(0.5))
                            }
                        }
                        .frame(height: 26)
                        Text(language == .english ? candidate.englishName : candidate.name)
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .medium))
                            .foregroundStyle(isOwned ? Color.tpInk : Color.tpSecondary.opacity(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(
                        isOwned ? Color.tpAccent.opacity(0.10) : Color.tpInk.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        if season.equippedAccessory == candidate.accessoryID {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.tpAccent, lineWidth: 1.4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    isOwned
                        ? (language == .english ? candidate.englishName : candidate.name)
                        : language.text("아직 모으지 못한 장식", "Not collected yet")
                )
            }
        }
    }

    @ViewBuilder
    private var archiveSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("지난해의 집", "Past homes"),
                subtitle: language.text("매년 새 모닥불에서 시작하고 이전 집은 보관해요", "Each year starts at the campfire; past homes stay saved")
            )
            if history.archives.isEmpty {
                Text(language.text("아직 보관된 집이 없어요.", "No archived homes yet."))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                    .foregroundStyle(Color.tpSecondary)
            } else {
                ForEach(history.archives.reversed(), id: \.year) { archive in
                    HStack(spacing: 10) {
                        Image(MapHomeGrowthPolicy.artworkName(level: archive.level))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(archive.year)")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold, design: .rounded))
                                .foregroundStyle(Color.tpInk)
                            Text("Lv.\(archive.level) · \(archive.chosenEvolutions.count) \(language.text("진화", "evolutions"))")
                                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                                .foregroundStyle(Color.tpSecondary)
                        }
                        Spacer()
                        Text("\(archive.landPlots.count) \(language.text("땅", "plots"))")
                            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                            .foregroundStyle(Color.tpSecondary)
                    }
                    .padding(10)
                    .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
            Text(subtitle)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    private var testToolsSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionTitle(
                language.text("시험 도구", "Test tools"),
                subtitle: language.text("레벨·보상·저장 형식을 임의로 바꿔 기능을 시험해요", "Change level, rewards, and storage shape to test")
            )
            Text(language.text("집 레벨", "Home level"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            testStepper(
                value: "Lv.\(season.level)",
                small: { setTestLevel(season.level - 1) },
                smallUp: { setTestLevel(season.level + 1) },
                large: { setTestLevel(season.level - 10) },
                largeUp: { setTestLevel(season.level + 10) }
            )
            Text(language.text("연속 달성일", "Streak days"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            testStepper(
                value: language.text("\(season.streak)일", "\(season.streak) days"),
                small: { adjustTestStreak(-1) },
                smallUp: { adjustTestStreak(1) },
                large: { adjustTestStreak(-7) },
                largeUp: { adjustTestStreak(7) }
            )
            Text(language.text("연속 일수가 7의 배수를 넘으면 주간 보상이 하나씩 생겨요.", "Each multiple of 7 streak days adds a weekly reward."))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
            Text(language.text("레벨 바로 가기", "Level presets"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach([1, 100, 200, 300, MapHomeGrowthPolicy.maximumLevel(year: season.year), 366], id: \.self) { level in
                    testButton("Lv.\(level)") { setTestLevel(level) }
                }
            }
            Text(language.text("보상·연속", "Rewards and streak"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                testButton(language.text("보상 +1", "Reward +1")) { addTestRewards(streakDays: 0) }
                testButton(language.text("연속 +7일(보상 +1)", "Streak +7 (reward +1)")) { addTestRewards(streakDays: 7) }
            }
            Text(language.text("저장 형식", "Storage shape"))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
            testButton(language.text("이전 형식으로 저장 후 다시 읽기", "Save in the old shape and reload")) { saveLegacyShape() }
            Text(language.text("2026은 365일이라 최대 365입니다. 366은 그림 미리보기용이고, 다음 기록 때 365로 돌아갑니다.", "2026 has 365 days, so the cap is 365. Lv.366 is an artwork preview and returns to the cap on the next record."))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium))
                .foregroundStyle(Color.tpSecondary)
        }
    }

    /// 값 한 줄과 −10(−7) / −1 / +1 / +10(+7) 버튼.
    private func testStepper(
        value: String,
        small: @escaping () -> Void,
        smallUp: @escaping () -> Void,
        large: @escaping () -> Void,
        largeUp: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            testButton("−\(value.contains("일") || value.contains("days") ? 7 : 10)", action: large)
            testButton("−1", action: small)
            Text(value)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(16)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .frame(minWidth: 72)
                .monospacedDigit()
            testButton("+1", action: smallUp)
            testButton("+\(value.contains("일") || value.contains("days") ? 7 : 10)", action: largeUp)
        }
    }

    private func adjustTestStreak(_ delta: Int) {
        var updated = history
        let before = updated.season.streak
        let after = max(0, before + delta)
        updated.season.streak = after
        if after > before {
            if !MapHomeLandmarkCatalog.isCollectionComplete(updated.season) {
                updated.season.pendingWeeklyRewards += after / 7 - before / 7
            }
        }
        save(updated)
    }

    private func testButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold, design: .rounded))
                .foregroundStyle(Color.tpInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func setTestLevel(_ level: Int) {
        var updated = history
        updated.season.level = min(max(level, 1), 366)
        save(updated)
    }

    private func addTestRewards(streakDays: Int) {
        var updated = history
        updated.season.streak += streakDays
        if !MapHomeLandmarkCatalog.isCollectionComplete(updated.season) {
            updated.season.pendingWeeklyRewards += 1
        }
        save(updated)
    }

    /// 예전 앱이 저장하던 모양(땅 배치·소급 보상 필드 없음)으로 저장해 읽기 호환을 시험한다.
    private func saveLegacyShape() {
        guard let encoded = try? JSONEncoder().encode(history),
              var object = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else { return }
        func stripped(_ season: [String: Any]) -> [String: Any] {
            var copy = season
            copy.removeValue(forKey: "landPlotPlacements")
            copy.removeValue(forKey: "recentCompletionRewardedDays")
            return copy
        }
        if let season = object["season"] as? [String: Any] { object["season"] = stripped(season) }
        if let archives = object["archives"] as? [[String: Any]] { object["archives"] = archives.map(stripped) }
        guard let legacy = try? JSONSerialization.data(withJSONObject: object) else { return }
        growthData = legacy
    }

    private func claim(_ candidate: MapHomeLandmarkCandidate) {
        var updated = history
        let plotID = "plot.\(UUID().uuidString)"
        guard MapHomeGrowthPolicy.redeemWeeklyReward(
            evolutionID: candidate.id,
            landPlotID: plotID,
            accessoryID: candidate.accessoryID,
            in: &updated
        ) else { return }
        save(updated)
    }

    private func place(_ plotID: String) {
        var updated = history
        guard MapHomeGrowthPolicy.placeLandPlot(plotID, in: &updated.season) else { return }
        save(updated)
    }

    private func equip(_ accessoryID: String) {
        var updated = history
        guard MapHomeGrowthPolicy.equipAccessory(accessoryID, in: &updated.season) else { return }
        save(updated)
    }

    private func save(_ history: MapHomeGrowthHistory) {
        guard growthData.isEmpty || historyCache.history(for: growthData) != nil,
              let encoded = try? JSONEncoder().encode(history) else { return }
        growthData = encoded
    }

    private func displayName(_ candidate: MapHomeLandmarkCandidate) -> String {
        language == .english ? candidate.englishName : candidate.name
    }

    private func countryName(_ korean: String) -> String {
        guard language == .english else { return korean }
        return [
            "대한민국": "South Korea", "일본": "Japan", "미국": "United States",
            "영국": "United Kingdom", "프랑스": "France", "이탈리아": "Italy",
            "중국": "China", "스페인": "Spain", "태국": "Thailand", "호주": "Australia",
        ][korean] ?? korean
    }

    private func categoryName(_ category: String) -> String {
        guard language == .english else { return category }
        return ["건축": "Architecture", "자연": "Nature", "문화": "Culture"][category] ?? category
    }

    private func accessoryName(_ accessoryID: String) -> String {
        guard let candidate = MapHomeLandmarkCatalog.candidates.first(where: { $0.accessoryID == accessoryID }) else {
            return language.text("화랑이 장식", "Hwarang accessory")
        }
        return language.text("\(candidate.name) 테마 장식", "\(candidate.englishName) charm")
    }
}
