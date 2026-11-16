import Foundation
import TaptionPlanCore

// MARK: - Automatic · routine · action record graph

enum RecordLayer: String, CaseIterable, Sendable {
    case automatic = "자동"
    case routine = "루틴"
    case action = "액션"
}

struct RecordGraphNode: Identifiable, Hashable, Sendable {
    let id: String
    let layer: RecordLayer
    let title: String
    let span: TimeSpan
    let categoryID: String?
}

struct RecordGraphEdge: Identifiable, Hashable, Sendable {
    let from: String
    let to: String
    var id: String { "\(from)->\(to)" }
}

struct RecordRelationshipGraph: Sendable {
    let nodes: [RecordGraphNode]
    let edges: [RecordGraphEdge]
    var isEmpty: Bool { nodes.isEmpty }
}

/// Keeps automatic evidence, a routine, and its concrete action as separate
/// nodes while exposing only explicit relationships. Time/category overlap is
/// deliberately not treated as a connection.
enum RecordRelationshipEngine {
    static func make(
        inside span: TimeSpan,
        plans: [PlanRecord],
        actuals: [ActualRecord],
        calendarEvents: [CalendarRecord],
        places: [PlaceStay],
        travel: [TravelSegment],
        recordLinks: [RecordLink] = [],
        focusNodeID: String? = nil
    ) -> RecordRelationshipGraph {
        var allNodes: [RecordGraphNode] = []
        var edges: [RecordGraphEdge] = []
        var nodeIDs = Set<String>()
        var edgeIDs = Set<String>()
        let plansByID = Dictionary(
            plans.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        allNodes.reserveCapacity(
            calendarEvents.count
                + places.count
                + travel.count
                + actuals.count
                + plans.count
        )

        func appendEdge(from: String, to: String) {
            let edge = RecordGraphEdge(from: from, to: to)
            guard edgeIDs.insert(edge.id).inserted else { return }
            edges.append(edge)
        }

        func append(_ node: RecordGraphNode, includeOutsideSpan: Bool = false) {
            guard includeOutsideSpan || node.span.intersection(with: span) != nil,
                  nodeIDs.insert(node.id).inserted else { return }
            allNodes.append(node)
        }

        for event in calendarEvents {
            append(RecordGraphNode(
                id: "automatic.calendar.\(event.id)",
                layer: .automatic,
                title: event.title,
                span: event.span,
                categoryID: "calendar"
            ))
        }
        for place in places {
            append(RecordGraphNode(
                id: "automatic.place.\(place.id.uuidString)",
                layer: .automatic,
                title: place.floor.map { "\(place.displayName) · \($0)층" } ?? place.displayName,
                span: place.span,
                categoryID: "location"
            ))
        }
        for segment in travel {
            append(RecordGraphNode(
                id: "automatic.travel.\(segment.id.uuidString)",
                layer: .automatic,
                title: MovementPresentation.title(for: segment.mode),
                span: segment.span,
                categoryID: "movement"
            ))
        }
        for actual in actuals where isAutomaticActual(actual) {
            append(RecordGraphNode(
                id: "automatic.actual.\(actual.id.uuidString)",
                layer: .automatic,
                title: actual.categoryID == "movement"
                    ? MovementPresentation.title(for: actual)
                    : actual.title,
                span: actual.span(),
                categoryID: actual.categoryID
            ))
        }

        // Repeat-rule segments are projections of a routine, not separate
        // relationship nodes. Keeping them here made one routine appear as
        // several duplicate cards and caused evidence to link to a phantom
        // action. The root routine owns the rule; concrete actions remain
        // separate nodes.
        for plan in plans where isRoutine(plan) {
            append(RecordGraphNode(
                id: "routine.\(plan.id.uuidString)",
                layer: .routine,
                title: GoalRecordPolicy.displayTitle(plan.title),
                span: plan.span,
                categoryID: plan.categoryID
            ), includeOutsideSpan: true)
        }
        for plan in plans where isAction(plan) {
            append(RecordGraphNode(
                id: "action.\(plan.id.uuidString)",
                layer: .action,
                title: plan.title,
                span: plan.span,
                categoryID: plan.categoryID
            ), includeOutsideSpan: true)
        }

        let routines = allNodes.filter { $0.layer == .routine }
        let actions = allNodes.filter { $0.layer == .action }
        for action in actions {
            guard let actionID = UUID(
                uuidString: action.id.replacingOccurrences(of: "action.", with: "")
            ), let routineID = rootRoutineID(
                for: actionID,
                plansByID: plansByID
            ) else {
                continue
            }
            let routineNodeID = "routine.\(routineID.uuidString)"
            guard routines.contains(where: { $0.id == routineNodeID }) else {
                continue
            }
            appendEdge(from: routineNodeID, to: action.id)
        }

        for actual in actuals {
            let actualNodeID = "automatic.actual.\(actual.id.uuidString)"
            guard nodeIDs.contains(actualNodeID) else { continue }
            if let routineID = routineID(
                for: actual,
                plansByID: plansByID
            ) {
                let nodeID = "routine.\(routineID.uuidString)"
                if nodeIDs.contains(nodeID) {
                    appendEdge(from: actualNodeID, to: nodeID)
                }
            }
            if let planID = actionID(
                for: actual,
                plansByID: plansByID
            ) {
                let nodeID = "action.\(planID.uuidString)"
                if nodeIDs.contains(nodeID) {
                    appendEdge(from: actualNodeID, to: nodeID)
                }
            }
        }

        for link in recordLinks {
            let from = canonicalNodeID(link.fromNodeID, plansByID: plansByID)
            let to = canonicalNodeID(link.toNodeID, plansByID: plansByID)
            guard from != to,
                  nodeIDs.contains(from),
                  nodeIDs.contains(to) else { continue }
            appendEdge(from: from, to: to)
        }

        let visibleIDs: Set<String>
        if let focusNodeID {
            let canonicalFocus = canonicalNodeID(focusNodeID, plansByID: plansByID)
            var connected = Set([canonicalFocus])
            var changed = true
            while changed {
                changed = false
                for edge in edges where connected.contains(edge.from) || connected.contains(edge.to) {
                    if connected.insert(edge.from).inserted { changed = true }
                    if connected.insert(edge.to).inserted { changed = true }
                }
            }
            visibleIDs = connected
        } else {
            visibleIDs = Set(
                allNodes
                    .filter { $0.span.intersection(with: span) != nil }
                    .map(\.id)
            )
        }
        let nodes = allNodes.filter { visibleIDs.contains($0.id) }
        let visibleEdges = edges.filter {
            visibleIDs.contains($0.from) && visibleIDs.contains($0.to)
        }
        return RecordRelationshipGraph(
            nodes: nodes.sorted { lhs, rhs in
                let leftLayer = RecordLayer.allCases.firstIndex(of: lhs.layer) ?? 0
                let rightLayer = RecordLayer.allCases.firstIndex(of: rhs.layer) ?? 0
                return leftLayer == rightLayer
                    ? lhs.span.start < rhs.span.start
                    : leftLayer < rightLayer
            },
            edges: visibleEdges
        )
    }

    private static func isAutomaticActual(_ actual: ActualRecord) -> Bool {
        actual.categoryID == "sleep"
            || actual.categoryID == "activity"
            || actual.source == .healthKit
            || actual.source == .appleWatch
            || actual.source == .motion
            || actual.source == .location
            || actual.source == .media
            || actual.source == .call
    }

    private static func isRoutine(_ plan: PlanRecord) -> Bool {
        GoalRecordPolicy.isGoal(plan)
    }

    private static func isAction(_ plan: PlanRecord) -> Bool {
        !GoalRecordPolicy.isGoal(plan)
            && plan.origin != .repeatRule
            && plan.origin != .calendar
    }

    private static func rootRoutineID(
        for planID: UUID,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        var currentID: UUID? = planID
        var visited = Set<UUID>()
        while let id = currentID,
              visited.insert(id).inserted,
              let plan = plansByID[id] {
            if GoalRecordPolicy.isGoal(plan) {
                return plan.id
            }
            currentID = plan.parentID
        }
        return nil
    }

    private static func routineID(
        for actual: ActualRecord,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        if let routineID = actual.routineID,
           let rootID = rootRoutineID(for: routineID, plansByID: plansByID) {
            return rootID
        }
        guard let planID = actual.planID else { return nil }
        return rootRoutineID(for: planID, plansByID: plansByID)
    }

    private static func actionID(
        for actual: ActualRecord,
        plansByID: [UUID: PlanRecord]
    ) -> UUID? {
        guard !AutomaticRecordTimelineEngine.linksOnlyToRoutine(actual),
              let planID = actual.planID,
              let plan = plansByID[planID],
              isAction(plan) else {
            return nil
        }
        return plan.id
    }

    private static func canonicalNodeID(
        _ nodeID: String,
        plansByID: [UUID: PlanRecord]
    ) -> String {
        let prefixes = ["routine.", "action."]
        guard let prefix = prefixes.first(where: { nodeID.hasPrefix($0) }),
              let id = UUID(uuidString: String(nodeID.dropFirst(prefix.count))) else {
            return nodeID
        }
        guard let plan = plansByID[id] else { return nodeID }
        if let rootID = rootRoutineID(for: plan.id, plansByID: plansByID) {
            if prefix == "routine." || plan.origin == .repeatRule {
                return "routine.\(rootID.uuidString)"
            }
        }
        return nodeID
    }

}
