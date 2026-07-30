import SwiftData
import SwiftUI

struct ScheduleView: View {
    @Bindable var model: AppModel
    @Query(sort: \PlanItem.startAt) private var storedPlans: [PlanItem]

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: headerTitle,
                trailing: headerTrailing,
                selectedScale: model.selectedScale,
                onScaleChange: { model.selectedScale = $0 }
            )
            TimelineBoard(model: model, scale: model.selectedScale, storedPlans: storedPlans)
        }
        .background(Color.white)
    }

    private var headerTitle: String {
        switch model.selectedScale {
        case .day: "7월 30일 목요일"
        case .week: "7월 27일 – 8월 2일"
        case .month: "2026년 7월"
        case .year: "2026년"
        }
    }

    private var headerTrailing: String {
        switch model.selectedScale {
        case .day: "☁︎ 23° · 흐림"
        case .week: "W31"
        case .month: "31일"
        case .year: "나의 한 해"
        }
    }
}

struct GroupGanttView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            DraftTopBar(
                title: "신제품 기획",
                trailing: "7.27 – 8.2",
                selectedScale: model.selectedScale,
                onScaleChange: { model.selectedScale = $0 },
                onBack: { model.detail = nil }
            )
            TimelineBoard(
                model: model,
                scale: model.selectedScale,
                storedPlans: [],
                isGroup: true
            )
        }
        .background(Color.white)
    }
}

private struct TimelineBoard: View {
    @Bindable var model: AppModel
    let scale: TimeScale
    let storedPlans: [PlanItem]
    var isGroup = false

    var body: some View {
        VStack(spacing: 0) {
            axis

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        TimelineRow(row: row) { block in
                            handleTap(block)
                        }
                    }

                    if scale == .day, !isGroup {
                        photoRow
                    } else {
                        summaryStrip
                    }
                }

                gridLines
                    .allowsHitTesting(false)

                currentLine
                    .allowsHitTesting(false)
            }
            .frame(height: contentHeight)

            Spacer(minLength: 0)
        }
        .background(Color.white)
    }

    private var axis: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 50)
            ForEach(scale.axisLabels, id: \.self) { label in
                Text(label)
                    .font(.system(size: 10, weight: label == highlightedAxisLabel ? .bold : .regular))
                    .foregroundStyle(label == highlightedAxisLabel ? Color.tpNow : Color.tpSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private var rows: [TimelineRowModel] {
        if isGroup {
            return groupRows
        }

        switch scale {
        case .day:
            var dayRows: [TimelineRowModel] = [
                .init(
                    title: "캘린더",
                    dotColor: Color(red: 0.56, green: 0.56, blue: 0.58),
                    blocks: [
                        .init(
                            title: "병원 14:00",
                            start: 0.47,
                            length: 0.22,
                            isFixed: true
                        )
                    ]
                ),
                .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "보고서 작성", start: 0.14, length: 0.44)]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "러닝 40분", start: 0.63, length: 0.20)]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "영어", start: 0.80, length: 0.17)]
                ),
                .init(
                    title: "생활",
                    category: .routine,
                    blocks: [.init(title: "점심", start: 0.38, length: 0.12)]
                ),
            ]

            dayRows += storedPlans.map { plan in
                TimelineRowModel(
                    title: plan.category.rawValue,
                    category: plan.category,
                    blocks: [.init(title: plan.title, start: 0.68, length: 0.22)]
                )
            }
            return dayRows

        case .week:
            return [
                .init(
                    title: "프로젝트",
                    category: .project,
                    height: 68,
                    blocks: [
                        .init(title: "신제품 기획", start: 0.02, length: 0.55, top: 8, groupCount: 4),
                        .init(title: "보고서", start: 0.44, length: 0.26, top: 38),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [
                        .init(title: "런", start: 0.02, length: 0.12),
                        .init(title: "런", start: 0.30, length: 0.12),
                        .init(title: "런", start: 0.58, length: 0.12),
                        .init(title: "런", start: 0.86, length: 0.12),
                    ]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "영어 매일 30분", start: 0.02, length: 0.83)]
                ),
            ]

        case .month:
            return [
                .init(
                    title: "프로젝트",
                    category: .project,
                    height: 68,
                    blocks: [
                        .init(title: "신제품 기획", start: 0.08, length: 0.44, top: 8, groupCount: 4),
                        .init(title: "월간 보고서", start: 0.62, length: 0.27, top: 38),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동", start: 0.02, length: 0.96)]
                ),
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 2단계", start: 0.16, length: 0.56)]
                ),
                .init(
                    title: "여행",
                    category: .travel,
                    blocks: [.init(title: "출발", start: 0.76, length: 0.20, top: 20, height: 20)]
                ),
            ]

        case .year:
            return [
                .init(
                    title: "학습",
                    category: .study,
                    blocks: [.init(title: "자격증 취득", start: 0.16, length: 0.34, groupCount: 3)]
                ),
                .init(
                    title: "여행",
                    category: .travel,
                    blocks: [
                        .init(title: "일본", start: 0.58, length: 0.10),
                        .init(title: "제주", start: 0.88, length: 0.10, top: 20, height: 20),
                    ]
                ),
                .init(
                    title: "운동",
                    category: .exercise,
                    blocks: [.init(title: "주 3회 운동 습관", start: 0.02, length: 0.96)]
                ),
                .init(
                    title: "프로젝트",
                    category: .project,
                    blocks: [.init(title: "신제품 프로젝트", start: 0.25, length: 0.42, groupCount: 4)]
                ),
            ]
        }
    }

    private var groupRows: [TimelineRowModel] {
        [
            .init(
                title: "조사",
                dotColor: .clear,
                blocks: [.init(title: "시장 조사", start: 0.02, length: 0.26)]
            ),
            .init(
                title: "분석",
                dotColor: .clear,
                blocks: [.init(title: "경쟁사 분석", start: 0.16, length: 0.26)]
            ),
            .init(
                title: "컨셉",
                dotColor: .clear,
                blocks: [.init(title: "컨셉 정리", start: 0.30, length: 0.28)]
            ),
            .init(
                title: "초안",
                dotColor: .clear,
                blocks: [.init(title: "보고서 초안", start: 0.58, length: 0.26)]
            ),
        ]
    }

    @ViewBuilder
    private var gridLines: some View {
        if scale == .day {
            GeometryReader { proxy in
                ForEach(0..<5, id: \.self) { index in
                    Rectangle()
                        .fill(Color(red: 0.96, green: 0.96, blue: 0.97))
                        .frame(width: 0.5)
                        .position(
                            x: 50 + (proxy.size.width - 50) * CGFloat(index) / 5,
                            y: proxy.size.height / 2
                        )
                }
            }
        }
    }

    private var currentLine: some View {
        GeometryReader { proxy in
            let x = proxy.size.width * nowFraction

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.tpNow)
                    .frame(width: 2, height: proxy.size.height)
                    .position(x: x, y: proxy.size.height / 2)

                Circle()
                    .fill(Color.tpNow)
                    .frame(width: 8, height: 8)
                    .position(x: x, y: 1)

                if scale == .day, !isGroup {
                    Text("14:05")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.tpNow, in: Capsule())
                        .fixedSize()
                        .position(x: x, y: 7)
                }
            }
        }
        .zIndex(20)
    }

    private var photoRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.tpPhotoDark)
                    .frame(width: 8, height: 8)
                Text("사진")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.tpInk)
            .padding(.leading, 8)
            .frame(width: 50, alignment: .leading)

            GeometryReader { proxy in
                photoMarker(at: 0.38, label: "11:42", style: .lunch, count: nil, proxy: proxy)
                photoMarker(at: 0.53, label: "13:56", style: .street, count: 2, proxy: proxy)
                photoMarker(at: 0.82, label: "18:22", style: .run, count: nil, proxy: proxy)
            }
        }
        .frame(height: 65)
        .background(Color(red: 0.99, green: 0.98, blue: 1.00))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(red: 0.95, green: 0.95, blue: 0.96)).frame(height: 0.5)
        }
    }

    private func photoMarker(
        at fraction: CGFloat,
        label: String,
        style: PhotoStyle,
        count: Int?,
        proxy: GeometryProxy
    ) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                PhotoThumbnail(style: style)
                    .frame(width: 39, height: 39)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.white, lineWidth: 2)
                    }
                    .shadow(color: .black.opacity(0.24), radius: 2.5, y: 1)

                if let count {
                    Text("+\(count)")
                        .font(.system(size: 7, weight: .black))
                        .foregroundStyle(.white)
                        .frame(minWidth: 17, minHeight: 17)
                        .background(Color.tpPhotoDark, in: Capsule())
                        .overlay { Capsule().stroke(.white, lineWidth: 1.5) }
                        .offset(x: 5, y: -5)
                }
            }
            Text(label)
                .font(.system(size: 6.5, weight: .black))
                .foregroundStyle(Color.tpPhotoDark)
        }
        .position(x: proxy.size.width * fraction, y: 32)
    }

    private var summaryStrip: some View {
        HStack(spacing: 0) {
            Text(summaryTitle)
                .font(.system(size: scale == .month ? 9 : 10, weight: .regular))
                .foregroundStyle(Color.tpSecondary)
                .padding(.leading, scale == .month ? 4 : 8)
                .frame(width: 50, alignment: .leading)

            HStack(spacing: 3) {
                ForEach(summaryColors.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(summaryColors[index].color.opacity(summaryColors[index].opacity))
                        .frame(height: 18)
                }
            }
            .padding(.horizontal, 3)
        }
        .frame(height: 46)
        .background(Color(red: 0.98, green: 0.98, blue: 0.985))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.tpLine).frame(height: 0.5)
        }
    }

    private var summaryTitle: String {
        switch scale {
        case .week, .day: "일 요약"
        case .month: "주·일 요약"
        case .year: "월 요약"
        }
    }

    private var summaryColors: [SummaryColor] {
        switch scale {
        case .week, .day:
            [
                .init(.tpProjectDark, 0.50), .init(.tpProjectDark, 0.32),
                .init(.tpStudyDark, 0.42), .init(.tpExerciseDark, 0.50),
                .init(.tpProjectDark, 0.60), .init(.tpHobbyDark, 0.30),
                .init(Color(red: 0.93, green: 0.93, blue: 0.94), 1),
            ]
        case .month:
            [
                .init(.tpProjectDark, 0.28), .init(.tpStudyDark, 0.42),
                .init(.tpExerciseDark, 0.38), .init(.tpProjectDark, 0.55),
                .init(.tpHobbyDark, 0.30), .init(.tpTravelDark, 0.48),
                .init(.tpExerciseDark, 0.24),
            ]
        case .year:
            [
                .init(.tpProjectDark, 0.18), .init(.tpProjectDark, 0.28),
                .init(.tpStudyDark, 0.45), .init(.tpStudyDark, 0.60),
                .init(.tpExerciseDark, 0.50), .init(.tpStudyDark, 0.35),
                .init(.tpProjectDark, 0.55), .init(.tpTravelDark, 0.50),
                .init(.tpHobbyDark, 0.35), .init(.tpHobbyDark, 0.22),
                .init(Color(red: 0.93, green: 0.93, blue: 0.94), 1),
                .init(Color(red: 0.93, green: 0.93, blue: 0.94), 1),
            ]
        }
    }

    private var contentHeight: CGFloat {
        rows.reduce(0) { $0 + $1.height } + (scale == .day && !isGroup ? 65 : 46)
    }

    private var nowFraction: CGFloat {
        if isGroup { return 0.54 }
        return switch scale {
        case .day: 0.603
        case .week: 0.54
        case .month: 0.94
        case .year: 0.57
        }
    }

    private var highlightedAxisLabel: String {
        switch scale {
        case .day: "15"
        case .week: "목"
        case .month: "30"
        case .year: "7"
        }
    }

    private func handleTap(_ block: TimelineBlock) {
        if block.groupCount != nil {
            model.detail = .group
            return
        }

        model.selectedAction = QuickActionItem(
            title: block.title,
            time: block.title == "영어" ? "21:00 → 22:00" : "09:00 → 12:00",
            context: block.title == "영어"
                ? "자격증 취득 › 이번 주 학습 · 계획 1시간"
                : "2026년 출시 목표 › 이번 주 기획안 확정"
        )
    }
}

private struct TimelineRow: View {
    let row: TimelineRowModel
    let onBlockTap: (TimelineBlock) -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if row.dotColor != .clear {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(row.dotColor)
                        .frame(width: 8, height: 8)
                }
                Text(row.title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .font(.system(size: row.title.count > 4 ? 9 : 10.5, weight: .semibold))
            .foregroundStyle(Color.tpInk)
            .padding(.leading, row.title.count > 4 ? 4 : 8)
            .frame(width: 50, alignment: .leading)

            GeometryReader { proxy in
                ForEach(row.blocks) { block in
                    let width = max(block.minimumWidth, proxy.size.width * block.length)
                    TimelineBar(block: block, color: row.fillColor, width: width)
                        .onTapGesture { onBlockTap(block) }
                        .position(
                            x: proxy.size.width * block.start
                                + width / 2,
                            y: block.top + block.height / 2
                        )
                }
            }
        }
        .frame(height: row.height)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(red: 0.95, green: 0.95, blue: 0.96))
                .frame(height: 0.5)
        }
    }
}

private struct TimelineBar: View {
    let block: TimelineBlock
    let color: Color
    let width: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            Text(block.title)
                .font(.system(size: block.height <= 20 ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(Color.tpInk.opacity(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let count = block.groupCount {
                Spacer(minLength: 1)
                Text("▸ \(count)")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.tpInk.opacity(0.62))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.70), in: Capsule())
            }
        }
        .padding(.horizontal, 6)
        .frame(
            width: width,
            height: block.height,
            alignment: .leading
        )
        .background {
            if block.isFixed {
                FixedStripeBackground()
            } else {
                color
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: block.height <= 20 ? 10 : 7, style: .continuous))
        .overlay {
            if block.isFixed {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(red: 0.78, green: 0.78, blue: 0.80), lineWidth: 1)
            }
        }
    }
}

private struct TimelineRowModel: Identifiable {
    let id = UUID()
    let title: String
    let category: PlanCategory?
    let dotColor: Color
    let height: CGFloat
    let blocks: [TimelineBlock]

    init(
        title: String,
        category: PlanCategory? = nil,
        dotColor: Color? = nil,
        height: CGFloat = 60,
        blocks: [TimelineBlock]
    ) {
        self.title = title
        self.category = category
        self.dotColor = dotColor ?? category?.darkColor ?? .clear
        self.height = height
        self.blocks = blocks
    }

    var fillColor: Color {
        category?.color ?? Color(red: 0.94, green: 0.94, blue: 0.95)
    }
}

private struct TimelineBlock: Identifiable {
    let id = UUID()
    let title: String
    let start: CGFloat
    let length: CGFloat
    let top: CGFloat
    let height: CGFloat
    let isFixed: Bool
    let groupCount: Int?
    let minimumWidth: CGFloat

    init(
        title: String,
        start: CGFloat,
        length: CGFloat,
        top: CGFloat = 16,
        height: CGFloat = 26,
        isFixed: Bool = false,
        groupCount: Int? = nil,
        minimumWidth: CGFloat = 18
    ) {
        self.title = title
        self.start = start
        self.length = length
        self.top = top
        self.height = height
        self.isFixed = isFixed
        self.groupCount = groupCount
        self.minimumWidth = minimumWidth
    }
}

private struct SummaryColor {
    let color: Color
    let opacity: Double

    init(_ color: Color, _ opacity: Double) {
        self.color = color
        self.opacity = opacity
    }
}

private enum PhotoStyle {
    case lunch
    case street
    case run
}

private struct PhotoThumbnail: View {
    let style: PhotoStyle

    var body: some View {
        ZStack {
            switch style {
            case .lunch:
                LinearGradient(
                    colors: [
                        Color(red: 0.49, green: 0.36, blue: 0.27),
                        Color(red: 0.84, green: 0.63, blue: 0.43),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(red: 0.96, green: 0.83, blue: 0.54))
                    .frame(width: 18, height: 18)
                    .overlay { Circle().stroke(Color(red: 0.85, green: 0.47, blue: 0.33), lineWidth: 5) }
            case .street:
                VStack(spacing: 0) {
                    Color(red: 0.62, green: 0.82, blue: 0.93)
                    Color(red: 0.91, green: 0.78, blue: 0.57).frame(height: 8)
                    Color(red: 0.47, green: 0.49, blue: 0.53)
                }
            case .run:
                VStack(spacing: 0) {
                    Color(red: 0.66, green: 0.84, blue: 0.94)
                    Color(red: 0.49, green: 0.70, blue: 0.46)
                    Color(red: 0.72, green: 0.46, blue: 0.31).frame(height: 9)
                }
            }
        }
    }
}

#Preview {
    ScheduleView(model: AppModel())
        .modelContainer(for: PlanItem.self, inMemory: true)
}
