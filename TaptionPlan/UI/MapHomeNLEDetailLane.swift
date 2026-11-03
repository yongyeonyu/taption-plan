import SwiftUI

/// 클립 편집기의 상세·센서 칸. 뒤에 센서 원본을 흐리게 깔고, 위에 하위 행동을 올린다(NLE1103A02).
extension MapHomeNLEClipEditor {
    /// HealthKit·iPhone 모션·GPS 같은 원본만으로 세운 구간(CAT1029A02, UIX1031A17: 다섯 줄). 고칠 수 없고, 견주어 보기만 한다.
    var sourceSegments: [MapHomeNLESensorSegment] {
        sensorEvidence
            .filter { $0.endMinute > $0.startMinute }
            .sorted { $0.startMinute < $1.startMinute }
    }

    func sourceColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        // 상세활동 뒤에 흐리게 겹쳐, 상세가 없는 시간에도 언제 무언가 기록됐는지 보인다.
        let sub = width
        return ZStack(alignment: .topLeading) {
            ForEach(sourceSegments) { segment in
                let y = geometry.y(forMinute: Double(segment.startMinute))
                let barHeight = max(3, geometry.height(minutes: Double(segment.endMinute - segment.startMinute)) - 2)
                sourceBar(segment, width: sub - 1, height: barHeight)
                    .frame(width: sub - 1, height: barHeight)
                    .offset(y: y + 1)
                sensorLabels(segment, geometry: geometry)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
    }

    /// 상세가 비어 있는 시간마다 걷기·정지 같은 원본 근거를 글자로 적는다. 움직임 아래에 헬스를 적어
    /// 겹치지 않게 하고, 나머지 줄은 누르면 값 창에 뜬다. 상세 블록 안에는 근거 줄이 따로 있다.
    @ViewBuilder
    private func sensorLabels(_ segment: MapHomeNLESensorSegment, geometry: NLETimelineGeometry) -> some View {
        if segment.channel.isRestorable {
            let row: CGFloat = segment.channel == .health ? 12 : 0
            ForEach(
                NLESensorLabelPlacement.freeRanges(
                    start: segment.startMinute, end: segment.endMinute, occupied: subTrack.clips
                ).filter { geometry.height(minutes: Double($0.count)) >= 15 + row },
                id: \.lowerBound
            ) { range in
                Text(segment.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .semibold))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .offset(y: geometry.y(forMinute: Double(range.lowerBound)) + 2 + row)
            }
        }
    }

    static func sensorTint(_ segment: MapHomeNLESensorSegment) -> Color {
        switch segment.channel {
        case .motion, .health: Self.tint(for: segment.categoryID)
        case .screen: Color.tpReferenceBlue
        case .network: Color.tpReferenceMint
        case .place: Color.tpPastelRose
        }
    }

    private func sourceBar(_ segment: MapHomeNLESensorSegment, width: CGFloat, height: CGFloat) -> some View {
        let tint = Self.sensorTint(segment)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(tint.opacity(0.22))
            .overlay {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(tint.opacity(0.6), lineWidth: 0.7)
            }
            .accessibilityHidden(true)
    }

    /// 하위 행동. 근거가 없는 시간은 비어 있고, 뒤의 센서 원본이 그대로 보인다.
    func detailColumn(geometry: NLETimelineGeometry, x: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(subTrack.clips) { clip in
                let y = geometry.y(forMinute: Double(clip.startMinute))
                let barHeight = max(3, geometry.height(minutes: Double(clip.lengthMinutes)) - 2)
                detailBar(clip, width: width, height: barHeight)
                    .frame(width: width, height: barHeight)
                    .offset(y: y + 1)
            }
        }
        .frame(width: width, alignment: .topLeading)
        .offset(x: x)
    }

    private func detailBar(_ clip: NLEClip, width: CGFloat, height: CGFloat) -> some View {
        let tint = Self.tint(for: clip.option.categoryID)
        let isSelected = clip.id == selectedSubClipID
        let provenance = subProvenance[clip.id]
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            // 뒤의 센서 글자가 비치지 않게 바탕을 먼저 깐다.
            .fill(Color.tpSurface)
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(tint.opacity(0.88))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        Color.white.opacity(isSelected ? 0.95 : 0.35),
                        lineWidth: isSelected ? 1.6 : 0.7
                    )
            }
            .overlay(alignment: .topLeading) {
                if height >= 15, width > 28 {
                    detailText(clip, provenance: provenance, height: height)
                }
            }
    }

    private func detailText(_ clip: NLEClip, provenance: NLESubActivityProvenance?, height: CGFloat) -> some View {
        let sensors = NLESensorEvidenceText.summary(
            sourceSegments, start: clip.startMinute, end: clip.endMinute, categoryID: clip.option.categoryID
        )
        let evidence = [provenance?.label(language), sensors.text.isEmpty ? nil : sensors.text]
            .compactMap { $0 }
            .joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                if provenance?.origin == .manual {
                    Image(systemName: "pencil")
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .bold))
                        .foregroundStyle(.white)
                        .accessibilityLabel(language.text("수동 기록", "Manual record"))
                }
                Text(clip.option.title)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(9)), weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            if height >= 26 {
                Text("\(Self.minuteLabel(clip.startMinute))–\(Self.minuteLabel(clip.endMinute))")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
            }
            if height >= 38, !evidence.isEmpty {
                Text(evidence)
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(8)), weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(max(1, Int((height - 26) / 11)))
            }
        }
        .padding(.leading, 4)
        // 줄이 화면 밖으로 넘치는 폭만큼 글자를 안쪽에서 끊는다.
        .padding(.trailing, 4 + Self.railBleed * 2)
        .padding(.top, 1)
        // 센서가 다른 분류로 봤으면 왼쪽 띠로 알린다.
        .overlay(alignment: .leading) {
            if sensors.differs { Rectangle().fill(Color.tpAccent).frame(width: 2) }
        }
    }
}
