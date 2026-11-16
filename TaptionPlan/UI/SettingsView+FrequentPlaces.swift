import MapKit
import SwiftUI

extension SettingsView {
    var frequentPlacesRow: some View {
        VStack(alignment: .leading, spacing: TaptionMenuMetrics.sectionSpacing) {
            HStack(spacing: TaptionMenuMetrics.sectionSpacing) {
                Image(systemName: "star.circle.fill")
                    .accessibilityHidden(true)
                    .font(.taption(size: 13))
                    .foregroundStyle(Color.tpPlaceDark)
                    .frame(width: 24, height: 24)
                    .background(
                        Color.tpPlace,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.tight)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text("자주가는 곳")
                        .font(
                            .taption(
                                size: SettingsTypography.rowTitle,
                                weight: .bold
                            )
                        )
                        .foregroundStyle(Color.tpInk)
                    Text("집 · 학교 · 학원 · 회사 · 식당을 현재 위치로 지정")
                        .font(.taption(size: SettingsTypography.rowSubtitle))
                        .foregroundStyle(Color.tpSecondary)
                }
                Spacer()
                Text(frequentPlacesSummary)
                    .font(
                        .taption(
                            size: SettingsTypography.value,
                            weight: .bold
                        )
                    )
                    .foregroundStyle(Color.tpPlaceDark)
            }

            if let suggestion = model.frequentPlaceSuggestion {
                suggestedPlaceCard(suggestion)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: TaptionMenuMetrics.compactSpacing),
                    GridItem(.flexible(), spacing: TaptionMenuMetrics.compactSpacing),
                ],
                spacing: TaptionMenuMetrics.compactSpacing
            ) {
                ForEach(model.settings.frequentPlaces) { place in
                    frequentPlaceChip(place)
                }
            }

            HStack(spacing: TaptionMenuMetrics.compactSpacing) {
                TextField("사용자 추가", text: $customFrequentPlaceName)
                    .font(.taption(size: 9, weight: .semibold))
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
                    .padding(.vertical, TaptionMenuMetrics.compactButtonVerticalPadding)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )

                Button {
                    model.addCustomFrequentPlace(name: customFrequentPlaceName)
                    customFrequentPlaceName = ""
                } label: {
                    Label("추가", systemImage: "plus")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
                        .padding(.vertical, TaptionMenuMetrics.compactButtonVerticalPadding)
                        .background(
                            Color.tpInk,
                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                        )
                }
                .buttonStyle(.plain)
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                .contentShape(Rectangle())
            }

            HStack(spacing: TaptionMenuMetrics.compactSpacing) {
                TextField("식당 추가", text: $restaurantName)
                    .font(.taption(size: 9, weight: .semibold))
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
                    .padding(.vertical, TaptionMenuMetrics.compactButtonVerticalPadding)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                    )

                Button {
                    model.addRestaurant(name: restaurantName)
                    restaurantName = ""
                } label: {
                    Label("식당 추가", systemImage: "storefront.fill")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
                        .padding(.vertical, TaptionMenuMetrics.compactButtonVerticalPadding)
                        .background(
                            Color.tpPlaceDark,
                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                        )
                }
                .buttonStyle(.plain)
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                .contentShape(Rectangle())
            }

            if !model.settings.floorCalibrationHistory.isEmpty {
                calibrationHistoryList
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.tpControlFill)
                .frame(height: 0.5)
        }
        .sheet(item: $selectedFrequentPlace) { place in
            FrequentPlaceDetailView(model: model, placeID: place.id)
        }
        .confirmationDialog(
            "어떤 곳인가요?",
            isPresented: $showsSuggestedPlaceKinds,
            titleVisibility: .visible
        ) {
            ForEach(FrequentPlaceKind.allCases, id: \.self) { kind in
                Button(kind.defaultName) {
                    guard let placeID = model.registerFrequentPlaceSuggestion(
                        as: kind
                    ) else {
                        return
                    }
                    selectedFrequentPlace = model.settings.frequentPlaces
                        .first { $0.id == placeID }
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("위치는 이미 채워져 있습니다. 이름과 감지 범위는 다음 화면에서 고칠 수 있습니다.")
        }
    }

    var userTransitLocationsRow: some View {
        settingsRow(
            icon: "tram.fill",
            iconBackground: Color.tpTransit.opacity(0.24),
            iconColor: Color.tpTransitDark,
            title: "사용자 등록 역·정류장",
            subtitle: "지하철역·버스정류장 이름과 유형 확인",
            value: "\(model.settings.userTransitLocations.count)개"
        ) {
            showsUserTransitLocations = true
        }
    }

    /// 등록되지 않은 자리를 한 번만 조용히 묻는다. "아니요"는 영구히 기억한다.
    private func suggestedPlaceCard(
        _ suggestion: FrequentPlaceSuggestion
    ) -> some View {
        VStack(alignment: .leading, spacing: TaptionMenuMetrics.tightSpacing) {
            HStack(spacing: TaptionMenuMetrics.tightSpacing) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.taption(size: 9, weight: .bold))
                    .foregroundStyle(Color.tpPlaceDark)
                Text("자주 가는데 등록되지 않은 곳")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                Spacer(minLength: 0)
            }

            Text(
                suggestion.suggestedName
                    ?? AppModel.coordinateLabel(suggestion.point)
            )
            .font(.taption(size: 9.5, weight: .bold))
            .foregroundStyle(Color.tpInk)
            .lineLimit(1)

            Text(suggestedPlaceSummary(suggestion))
                .font(.taption(size: 7.2, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)

            HStack(spacing: TaptionMenuMetrics.compactSpacing) {
                Button {
                    showsSuggestedPlaceKinds = true
                } label: {
                    Text("등록")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, TaptionMenuMetrics.suggestionButtonHorizontalPadding)
                        .padding(.vertical, TaptionMenuMetrics.compactButtonVerticalPadding)
                        .background(
                            Color.tpInk,
                            in: RoundedRectangle(cornerRadius: TaptionRadius.control)
                        )
                }
                .buttonStyle(.plain)
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                .contentShape(Rectangle())

                Button {
                    model.dismissFrequentPlaceSuggestion()
                } label: {
                    Text("아니요")
                        .font(.taption(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                        .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
                        .padding(.vertical, TaptionMenuMetrics.compactButtonVerticalPadding)
                }
                .buttonStyle(.plain)
                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                .contentShape(Rectangle())
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.tpBackground,
            in: RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
        )
    }

    private func suggestedPlaceSummary(
        _ suggestion: FrequentPlaceSuggestion
    ) -> String {
        let period = suggestion.reason == .weekly ? "최근 한 주" : "최근 한 달"
        let coordinates = AppModel.coordinateLabel(suggestion.point)
        guard suggestion.suggestedName != nil else {
            return "\(period)에 \(suggestion.visitCount)번 머물렀습니다."
        }
        return "\(period)에 \(suggestion.visitCount)번 머물렀습니다 · \(coordinates)"
    }

    private var calibrationHistoryList: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.tight) {
            Text("캘리브레이션 히스토리")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpSecondary)
            ForEach(
                model.settings.floorCalibrationHistory.suffix(10).reversed()
            ) { event in
                HStack(spacing: TaptionSpacing.compact) {
                    Image(
                        systemName: event.isAutomatic
                            ? "wand.and.stars"
                            : "hand.tap"
                    )
                    .font(.taption(size: 8))
                    .foregroundStyle(Color.tpPlaceDark)
                    Text("\(event.placeName) \(FloorLabel.korean(event.floor))")
                    .font(.taption(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                    Text(event.isAutomatic ? "자동" : "수동")
                        .font(.taption(size: 7.5))
                        .foregroundStyle(Color.tpSecondary)
                    Spacer(minLength: 4)
                    Text(
                        event.capturedAt,
                        format: .dateTime.month().day().hour().minute()
                    )
                    .font(.taption(size: 7.5))
                    .foregroundStyle(Color.tpSecondary)
                }
            }
        }
        .padding(.top, 3)
    }

    private var frequentPlacesSummary: String {
        let pinned = model.settings.frequentPlaces.filter {
            $0.point != nil
        }.count
        return "\(pinned)/\(model.settings.frequentPlaces.count)"
    }

    private func frequentPlaceChip(_ place: FrequentPlace) -> some View {
        Button {
            selectedFrequentPlace = place
        } label: {
            VStack(alignment: .leading, spacing: TaptionMenuMetrics.tightSpacing) {
                HStack(spacing: TaptionMenuMetrics.tightSpacing) {
                    Image(systemName: place.kind.systemImage)
                        .font(.taption(size: 9, weight: .bold))
                        .foregroundStyle(Color.tpPlaceDark)
                    Text(place.name)
                        .font(.taption(size: 8.8, weight: .bold))
                        .foregroundStyle(Color.tpInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if place.point != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .accessibilityHidden(true)
                            .font(.taption(size: 8.8, weight: .bold))
                            .foregroundStyle(Color.tpPlaceDark)
                    }
                    Image(systemName: "chevron.right")
                        .accessibilityHidden(true)
                        .font(.taption(size: 7.5, weight: .bold))
                        .foregroundStyle(Color.tpSecondary)
                }

                Text(frequentPlaceSubtitle(place))
                    .font(.taption(size: 7.2, weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)

                Text("탭하여 위치·감지 범위 설정")
                    .font(.taption(size: 6.8, weight: .medium))
                    .foregroundStyle(Color.tpSecondary.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.horizontal, TaptionMenuMetrics.chipHorizontalPadding)
            .padding(.vertical, TaptionMenuMetrics.compactRowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.tpBackground,
                in: RoundedRectangle(cornerRadius: TaptionRadius.field, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
        .contentShape(Rectangle())
    }

    private func frequentPlaceSubtitle(_ place: FrequentPlace) -> String {
        guard place.point != nil else { return "미지정" }
        let floor = place.floor.map { " · \($0)층" } ?? ""
        return "지정됨\(floor) · 반경 \(Int(place.radiusMeters))m"
    }
}
