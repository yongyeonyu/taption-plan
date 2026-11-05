import SwiftUI
import UIKit
import MapKit

extension TimelineDetailPanel {
    var availableDetailSections: [TimelineDetailSection] {
        let visible = TimelineDetailSection.defaultOrder.filter { section in
            if TaptionProductScope.automaticLoggingOnly {
                switch section {
                case .routine, .action, .event:
                    return false
                default:
                    break
                }
            }
            return switch section {
            case .schedule:
                hasScheduleContent
            case .location:
                hasLocationContent
            case .movement:
                hasMovementContent
            case .sleep:
                hasSleepContent
            case .activity:
                hasActivityContent
            case .appUsage:
                hasAppUsageContent
            case .weather:
                hasWeatherContent
            case .routine:
                hasRoutineContent
            case .action:
                hasActionContent
            case .photo:
                activePhotoCluster != nil
            case .memo:
                hasMemoContent
            case .event:
                hasEventContent
            case .map:
                hasMapContent
            }
        }
        let ordered = TimelineRowOrder.ordered(
            visible.filter { detailRowID(for: $0) != nil },
            id: { detailRowID(for: $0) ?? "" },
            savedIDs: model.snapshot.settings.timelineRowOrder
        )
        let extras = visible.filter {
            detailRowID(for: $0) == nil && $0 != .map
        }
        var result = ordered
        if visible.contains(.map) {
            // 지도는 별도 행이 아니라 위치·이동의 상세 내용이다. 상단
            // 시간표에서 같은 행의 뒤에 삽입해 카드 순서를 유지한다.
            let anchorID = activeSelection?.isRoute == true
                ? "movement"
                : "location"
            let insertion = result.firstIndex {
                detailRowID(for: $0) == anchorID
            }.map { $0 + 1 } ?? result.count
            result.insert(.map, at: min(insertion, result.count))
        }
        return result + extras
    }

    func detailRowID(
        for section: TimelineDetailSection
    ) -> String? {
        section.rowKind?.rawValue
    }

    func ensureVisibleDetailSection() {
        guard let first = availableDetailSections.first else { return }
        if !availableDetailSections.contains(section) {
            section = first
        }
    }

    var detailContextHeader: some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.compact) {
            if playheadDetailSections.isEmpty {
                detailContextTitle
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: TaptionSpacing.compact) {
                        ForEach(playheadDetailSections) { item in
                            Button {
                                section = item
                            } label: {
                                Label(item.rawValue, systemImage: item.systemImage)
                                    .font(.taption(size: 8.5, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .foregroundStyle(
                                        section == item
                                            ? Color.tpSurface
                                            : Color.tpInk
                                    )
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(
                                        section == item
                                            ? Color.tpProjectDark
                                            : Color.tpSurface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(item.rawValue) 상세 보기")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            if !playheadDetailSections.isEmpty {
                detailContextTitle
                    .padding(.horizontal, 10)
            }
        }
        .padding(.vertical, 6)
        .background(Color.tpSky.opacity(0.18))
    }

    var playheadDetailSections: [TimelineDetailSection] {
        availableDetailSections.filter { $0 != .map }
    }

    @ViewBuilder
    func detailCard(
        for item: TimelineDetailSection
    ) -> some View {
        let isFocused = activeSelection?.preferredDetailSection == item
            || (focusedRoutineForDetail != nil && item == .routine)
            || (activeSelection != nil && section == item)
        VStack(alignment: .leading, spacing: TaptionSpacing.cozy) {
            Group {
                switch item {
                case .schedule:
                    scheduleContent
                case .location:
                    locationContent
                case .movement:
                    movementContent
                case .sleep:
                    sleepContent
                case .activity:
                    activityContent
                case .appUsage:
                    appUsageContent
                case .weather:
                    weatherContent
                case .routine:
                    routineContent
                case .action:
                    actionContent
                case .photo:
                    photoContent
                case .memo:
                    memoContent
                case .event:
                    eventContent
                case .map:
                    routeContent
                }
            }
            // 메모 카드는 이미 그 구간의 메모를 전부 펴 놓았다. 여기서 또
            // 붙이면 같은 메모가 두 번 나온다.
            if item != .memo,
               activeSelection?.preferredDetailSection == item {
                DetailMemoList(
                    model: model,
                    selection: activeSelection,
                    section: item
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            isFocused
                ? Color.tpInk.opacity(0.035)
                : Color.tpSurface,
            in: RoundedRectangle(cornerRadius: TaptionRadius.panel, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.panel, style: .continuous)
                .stroke(
                    isFocused
                        ? Color.tpInk.opacity(0.34)
                        : Color.tpLine.opacity(0.75),
                    lineWidth: isFocused ? 1 : 0.5
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.rawValue) 상세")
    }

    func appUsageRow(_ actual: ActualRecord) -> some View {
        let span = actual.span()
        let isSelected = selectedActual?.id == actual.id
        return HStack(alignment: .top, spacing: TaptionSpacing.cozy) {
            Image(systemName: "app.badge.clock")
                .font(.taption(size: 9, weight: .bold))
                .foregroundStyle(Color.tpProjectDark)
            VStack(alignment: .leading, spacing: 1) {
                Text(actual.title)
                    .font(.taption(size: 9, weight: .semibold))
                AppUsageNameLabel(
                    record: actual,
                    tokenIndex: model.appUsageTokenIndex,
                    size: 9
                )
                Text(
                    "\(span.start.formatted(date: .omitted, time: .shortened))–\(span.end.formatted(date: .omitted, time: .shortened)) · \(ScreenTimeUsageRecordEngine.durationText(span.duration) ?? "1분 미만")"
                )
                .font(.taption(size: 7.5))
                .foregroundStyle(Color.tpSecondary)
                if isSelected {
                    ForEach(actual.evidence, id: \.self) { evidence in
                        Text("· \(evidence)")
                            .font(.taption(size: 7.5))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
