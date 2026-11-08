import Foundation
import TaptionPlanEngine

/// 기간 안의 자동·수동 기록을 카테고리 → 항목의 두 단계로 접는다.
/// 화면은 이 결과만 그리고, 제스처 중에는 다시 계산하지 않는다.
enum ActualRecordGroupingEngine {
    static func groups(
        actuals: [ActualRecord],
        in span: TimeSpan,
        categories: [CategoryDefinition],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordCategoryGroup] {
        groups(
            actuals: actuals,
            in: [span],
            categories: categories,
            asOf: asOf,
            scope: scope
        )
    }

    /// 고른 칸이 여럿일 때도 목록은 하나다. 기록을 칸마다 잘라 담고 같은
    /// 항목의 조각을 합쳐, 떨어진 칸을 골라도 합계가 겹쳐 세어지지 않는다.
    static func groups(
        actuals: [ActualRecord],
        in spans: [TimeSpan],
        categories: [CategoryDefinition],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordCategoryGroup] {
        var seen = Set<UUID>()
        var byCategory: [String: [(record: ActualRecord, span: TimeSpan)]] = [:]

        for actual in actuals {
            guard seen.insert(actual.id).inserted else { continue }
            let id = scope.categoryID(for: actual)
            for span in spans {
                let limit = min(asOf, span.end)
                guard actual.startedAt < limit,
                      let visible = actual.span(asOf: limit)
                          .intersection(with: span),
                      visible.duration > 0 else {
                    continue
                }
                byCategory[id, default: []].append((actual, visible))
            }
        }

        let definitions = definitionsByID(categories)

        return byCategory
            .map { categoryID, values in
                let children = mergedChildren(values, scope: scope)
                let definition = definitions[categoryID]
                return RecordCategoryGroup(
                    id: categoryID,
                    name: displayName(
                        categoryID: categoryID,
                        definition: definition
                    ),
                    colorHex: definition?.darkHex,
                    icon: definition?.icon,
                    duration: children.reduce(0) { $0 + $1.duration },
                    dominantChildTitle: children
                        .max { $0.duration < $1.duration }?
                        .title,
                    children: children
                )
            }
            .sorted {
                $0.duration == $1.duration
                    ? $0.id < $1.id
                    : $0.duration > $1.duration
            }
    }

    /// 하루 원형의 바깥 일과와 그 안에서 실제로 측정된 활동을 한 단계로
    /// 묶는다. 일과 구간은 서로 겹치지 않으므로 상위 합계가 하루 구간과
    /// 같고, 하위 활동은 해당 일과 안에서만 합산된다.
    static func phaseGroups(
        phases: [DayPhaseSpan],
        actuals: [ActualRecord],
        categories: [CategoryDefinition],
        asOf: Date = .now,
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordCategoryGroup] {
        let definitions = definitionsByID(categories)
        var spansByPhase: [DayPhase: [TimeSpan]] = [:]
        for phase in phases {
            spansByPhase[scope.phase(phase.phase), default: []].append(phase.span)
        }

        var phaseStarts: [String: Date] = [:]
        var result: [RecordCategoryGroup] = []
        for (phase, spans) in spansByPhase {
            let merged = ActualIntervalMergeEngine.union(spans)
            var values: [(record: ActualRecord, span: TimeSpan)] = []
            for actual in actuals {
                guard actual.behavior != "unconfirmed-gap" else { continue }
                let actualSpan = actual.span(asOf: asOf)
                for phaseSpan in merged {
                    guard let visible = actualSpan.intersection(with: phaseSpan)
                    else { continue }
                    values.append((record: actual, span: visible))
                }
            }
            let children = mergedChildren(values, scope: scope)
            let definition = definitions[phase.rawValue]
            phaseStarts[phase.rawValue] = merged.first?.start ?? .distantFuture
            let duration = merged.reduce(0) { $0 + $1.duration }
            let dominantChild = children.max { $0.duration < $1.duration }?.title
            result.append(RecordCategoryGroup(
                id: phase.rawValue,
                name: phase.title,
                colorHex: definition?.darkHex,
                icon: definition?.icon,
                duration: duration,
                dominantChildTitle: dominantChild,
                children: children
            ))
        }
        return result.sorted {
            let left = phaseStarts[$0.id] ?? .distantFuture
            let right = phaseStarts[$1.id] ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
    }

    /// 자동 기록은 같은 제목이 하루에 여러 번 끊겨 들어온다. 제목이 같으면
    /// 한 줄로 합치고 겹치는 구간은 한 번만 센다. 한 기록이 고른 칸 여럿에
    /// 걸쳐 잘렸을 때는 조각이 아니라 기록을 센다.
    private static func mergedChildren(
        _ values: [(record: ActualRecord, span: TimeSpan)],
        scope: RecordAnalysisScope = .legacy
    ) -> [RecordGroupChild] {
        Dictionary(grouping: values) {
            childTitle($0.record, scope: scope).lowercased()
        }
            .values
            .compactMap { entries -> RecordGroupChild? in
                let ordered = entries.sorted { $0.span.start < $1.span.start }
                guard let first = ordered.first else { return nil }
                return RecordGroupChild(
                    id: first.record.id.uuidString,
                    title: childTitle(first.record, scope: scope),
                    duration: ActualIntervalMergeEngine.duration(
                        of: ordered.map(\.span)
                    ),
                    start: first.span.start,
                    recordID: first.record.id,
                    occurrenceCount: Set(ordered.map(\.record.id)).count
                )
            }
            .sorted {
                $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start
            }
    }

    private static func childTitle(
        _ actual: ActualRecord,
        scope: RecordAnalysisScope
    ) -> String {
        switch scope {
        case .legacy:
            if ActualRecordCategoryResolver.categoryID(for: actual) == "movement" {
                return MovementPresentation.title(for: actual)
            }
            let trimmed = actual.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty { return trimmed }
            return TimelineRowKind.title(forCategoryID: actual.categoryID)
                ?? actual.categoryID
        case .canonical:
            return RecordAnalysisCategoryPolicy.detailTitle(for: actual)
        }
    }

    private static func definitionsByID(
        _ categories: [CategoryDefinition]
    ) -> [String: CategoryDefinition] {
        Dictionary(
            categories.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func displayName(
        categoryID: String,
        definition: CategoryDefinition?
    ) -> String {
        // 어플·날씨처럼 사용자 카테고리에 없는 자동 줄도 한글 이름을 갖는다.
        if categoryID == ReviewCoverageEngine.unconfirmedCategoryID {
            return "미확인"
        }
        if let name = definition?.name { return name }
        return TimelineRowKind.title(forCategoryID: categoryID) ?? categoryID
    }
}
