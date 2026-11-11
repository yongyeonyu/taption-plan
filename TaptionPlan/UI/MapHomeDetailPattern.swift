import SwiftUI

/// 사이드바 막대에서 상세 분류를 대분류 색 위 무늬로 보인다(DTP1111A01, 대표: 상세마다 다른 무늬, 이동·수면 포함).
/// 한 대분류 안의 상세끼리는 무늬가 겹치지 않는다. 대분류의 기본 상세(근무·쉼·식사·코어 수면 등)는 무늬 없이 색만.
enum MapHomeDetailPattern: String, CaseIterable, Hashable {
    case diagonal, backDiagonal, horizontal, vertical, grid, crosshatch, dots, waves, zigzag, chevron

    static func pattern(for behavior: String?) -> MapHomeDetailPattern? {
        behavior.flatMap { table[$0] }
    }

    private static let table: [String: MapHomeDetailPattern] = [
        // 업무·수업
        "meeting": .diagonal, "academy": .diagonal, "walking": .dots,
        // 이동
        "running": .chevron, "automotive": .horizontal, "subway": .vertical, "train": .grid,
        "bus": .backDiagonal, "cycling": .zigzag, "ship": .waves, "airplane": .crosshatch,
        // 수면
        "deep": .crosshatch, "rem": .waves, "nap": .dots,
        // 식사·운동
        "coffee": .dots, "exercise": .zigzag,
        // 건강관리
        "hospital": .crosshatch, "salon": .backDiagonal, "recovery": .horizontal, "medication": .vertical, "meditation": .waves,
        // 활동
        "zoningOut": .waves, "shower": .vertical, "friends": .diagonal, "dating": .backDiagonal, "family": .grid, "phoneCall": .horizontal,
        // 취미
        "hobby": .zigzag, "reading": .horizontal, "gaming": .grid, "music": .waves, "video": .vertical, "petCare": .dots,
        // 집안일
        "chores": .diagonal, "laundry": .waves, "groceries": .dots, "cooking": .grid, "dishes": .vertical,
    ]
}

/// 막대 위에 무늬를 칠할 분 범위.
struct MapHomeRailDetailSpan: Hashable {
    let range: Range<Int>
    let pattern: MapHomeDetailPattern
}

extension MapHomeTimeSidebarMath {
    /// 구간 자체의 상세 무늬와, 구간 안에 낀 상세 조각(일정의 회의·등록 지점 안 걷기)의 무늬.
    /// 조각은 제 무늬가 없는 머문 구간에만 얹는다. 이동·수면·미확인 구간은 제 상세 무늬를 쓴다.
    static func detailPatternSpans(
        _ pieces: [MapHomeRailDetailSpan],
        segments: [MapHomeTimeRailSegment],
        window: ClosedRange<Int>
    ) -> [MapHomeRailDetailSpan] {
        var result: [MapHomeRailDetailSpan] = []
        func add(_ lower: Int, _ upper: Int, _ pattern: MapHomeDetailPattern) {
            let start = max(lower, window.lowerBound), end = min(upper, window.upperBound)
            if start < end { result.append(MapHomeRailDetailSpan(range: start..<end, pattern: pattern)) }
        }
        for segment in segments {
            if let own = MapHomeDetailPattern.pattern(for: segment.behavior) {
                add(segment.startMinute, segment.endMinute, own)
                continue
            }
            guard !["movement", "sleep", "unconfirmed"].contains(segment.categoryID) else { continue }
            for piece in pieces {
                add(max(piece.range.lowerBound, segment.startMinute), min(piece.range.upperBound, segment.endMinute), piece.pattern)
            }
        }
        return result
    }
}

/// 대분류 색은 그대로 두고 상세 활동을 표시하는 흰 무늬.
struct MapHomeDetailPatternView: View {
    let pattern: MapHomeDetailPattern

    var body: some View {
        Canvas { context, size in
            context.stroke(path(in: size), with: .color(.white.opacity(0.5)), lineWidth: pattern == .dots ? 2.2 : 1.4)
        }
        .allowsHitTesting(false)
    }

    private func path(in size: CGSize) -> Path {
        let gap: CGFloat = 6
        var path = Path()
        func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
        let (w, h) = (size.width, size.height)
        switch pattern {
        case .diagonal, .backDiagonal, .crosshatch:
            var offset = -w
            while offset < h + w {
                if pattern != .backDiagonal { line(CGPoint(x: 0, y: offset + w), CGPoint(x: w, y: offset)) }
                if pattern != .diagonal { line(CGPoint(x: 0, y: offset), CGPoint(x: w, y: offset + w)) }
                offset += gap + 1
            }
        case .horizontal, .grid:
            for y in stride(from: gap / 2, through: h, by: gap) { line(CGPoint(x: 0, y: y), CGPoint(x: w, y: y)) }
            if pattern == .grid { for x in stride(from: gap / 2, through: w, by: gap) { line(CGPoint(x: x, y: 0), CGPoint(x: x, y: h)) } }
        case .vertical:
            for x in stride(from: gap / 2, through: w, by: gap / 1.5) { line(CGPoint(x: x, y: 0), CGPoint(x: x, y: h)) }
        case .dots:
            for y in stride(from: gap / 2, through: h, by: gap) {
                for x in stride(from: gap / 2, through: w, by: gap) { line(CGPoint(x: x, y: y), CGPoint(x: x + 0.1, y: y)) }
            }
        case .waves, .zigzag, .chevron:
            for y in stride(from: 0, through: h + gap, by: gap) {
                path.move(to: CGPoint(x: 0, y: y))
                for x in stride(from: gap / 2, through: w + gap, by: gap / 2) {
                    let up = Int(x / (gap / 2)).isMultiple(of: 2)
                    let target = CGPoint(x: x, y: y + (up ? -2 : 2))
                    if pattern == .waves {
                        path.addQuadCurve(to: target, control: CGPoint(x: x - gap / 4, y: y + (up ? 2 : -2)))
                    } else if pattern == .chevron {
                        path.addLine(to: CGPoint(x: x, y: y + (x < w / 2 ? -x / 2 : -(w - x) / 2)))
                    } else {
                        path.addLine(to: target)
                    }
                }
            }
        }
        return path
    }
}

/// 사이드바를 길게 누르면 뜨는 무늬 범례. 무늬가 있는 상세만 대분류별로 보인다.
struct MapHomeDetailPatternLegend: View {
    let language: MapHomeLanguage
    let categoryColorHex: (String) -> String

    var body: some View {
        NavigationStack {
            List {
                ForEach(RecordClassificationCatalog.categories.filter { $0.details.contains { MapHomeDetailPattern.pattern(for: $0.behavior) != nil } }, id: \.id) { category in
                    Section(category.localizedTitle(language)) {
                        ForEach(category.details.filter { MapHomeDetailPattern.pattern(for: $0.behavior) != nil }, id: \.id) { detail in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color(hex: categoryColorHex(category.id)))
                                    .overlay { MapHomeDetailPattern.pattern(for: detail.behavior).map(MapHomeDetailPatternView.init) }
                                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                    .frame(width: 34, height: 22)
                                Text(detail.localizedTitle(language))
                                    .font(.taptionStyle(.body))
                            }
                        }
                    }
                }
            }
            .navigationTitle(language.text("상세 무늬", "Detail patterns"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
