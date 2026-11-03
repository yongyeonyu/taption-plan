import Charts
import SwiftUI

struct SubwayRouteTimelineView: View {
    private struct StationNode: Identifiable {
        let id: String
        let name: String
        var lineNames: [String]
        var routeIndex: Int
        var isTransfer: Bool
    }

    let route: SubwayRoutePath
    let span: TimeSpan
    var isCompact = false

    private var nodes: [StationNode] {
        var result: [StationNode] = []
        for (index, stop) in route.stops.enumerated() {
            let normalized = normalizedStationName(stop.stationName)
            if let last = result.last,
               normalizedStationName(last.name) == normalized {
                var value = last
                if !value.lineNames.contains(stop.lineName) {
                    value.lineNames.append(stop.lineName)
                }
                value.routeIndex = index
                value.isTransfer = true
                result[result.count - 1] = value
                continue
            }
            result.append(
                StationNode(
                    id: "\(index).\(normalized).\(stop.lineName)",
                    name: stop.stationName,
                    lineNames: [stop.lineName],
                    routeIndex: index,
                    isTransfer: route.transferStationNames.contains {
                        normalizedStationName($0) == normalized
                    }
                )
            )
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 9) {
            HStack(alignment: .firstTextBaseline, spacing: TaptionSpacing.snug) {
                Label("지하철 노선", systemImage: "tram.fill")
                    .font(.taption(
                        size: isCompact ? 8 : 11,
                        weight: .bold
                    ))
                    .foregroundStyle(Color.tpProjectDark)
                Spacer(minLength: 4)
                Text(route.lineNames.joined(separator: " → "))
                    .font(.taption(
                        size: isCompact ? 6.8 : 9,
                        weight: .semibold
                    ))
                    .foregroundStyle(Color.tpSecondary)
                    .lineLimit(1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        stationNode(node, isLast: index == nodes.count - 1)
                    }
                }
                .padding(.horizontal, isCompact ? 2 : 4)
            }

            if !route.transferStationNames.isEmpty {
                Label(
                    route.transferStationNames
                        .map { "\(stationTitle($0)) 환승" }
                        .joined(separator: " · "),
                    systemImage: "arrow.triangle.swap"
                )
                .font(.taption(size: isCompact ? 6.8 : 9, weight: .semibold))
                .foregroundStyle(Color.tpPlaceDark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(isCompact ? 8 : 12)
        .background(
            Color.tpProject.opacity(0.12),
            in: RoundedRectangle(cornerRadius: isCompact ? 10 : 13)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func stationNode(
        _ node: StationNode,
        isLast: Bool
    ) -> some View {
        let width: CGFloat = isCompact ? 54 : 70
        return VStack(spacing: isCompact ? 2 : 4) {
            Text(timeText(for: node))
                .font(.taption(size: isCompact ? 6 : 8))
                .foregroundStyle(Color.tpSecondary)
            ZStack {
                if !isLast {
                    Rectangle()
                        .fill(Color.tpProjectDark.opacity(0.45))
                        .frame(width: width, height: 2)
                        .offset(x: width / 2)
                }
                Circle()
                    .fill(node.isTransfer ? Color.tpPlaceDark : Color.tpProjectDark)
                    .frame(width: isCompact ? 7 : 9, height: isCompact ? 7 : 9)
                    .overlay(
                        Circle().stroke(Color.white, lineWidth: isCompact ? 1 : 1.5)
                    )
            }
            .frame(width: width, height: isCompact ? 8 : 10)
            Text(stationTitle(node.name))
                .font(.taption(
                    size: isCompact ? 6.3 : 8.5,
                    weight: node.isTransfer ? .bold : .medium
                ))
                .foregroundStyle(node.isTransfer ? Color.tpPlaceDark : Color.tpInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: width)
            if node.isTransfer {
                Text("환승")
                    .font(.taption(size: isCompact ? 5.8 : 7.5, weight: .bold))
                    .foregroundStyle(Color.tpPlaceDark)
            } else {
                Text(" ")
                    .font(.taption(size: isCompact ? 5.8 : 7.5))
            }
        }
        .frame(width: width)
    }

    private func timeText(for node: StationNode) -> String {
        if node.routeIndex == 0 {
            return span.start.formatted(date: .omitted, time: .shortened)
        }
        if node.routeIndex == route.stops.count - 1 {
            return span.end.formatted(date: .omitted, time: .shortened)
        }
        return " "
    }

    private func stationTitle(_ name: String) -> String {
        name.hasSuffix("역") ? name : "\(name)역"
    }

    private func normalizedStationName(_ name: String) -> String {
        let compact = name.filter { !$0.isWhitespace }
        return compact.hasSuffix("역") ? String(compact.dropLast()) : compact
    }

    private var accessibilityText: String {
        let stationNames = nodes.map { stationTitle($0.name) }
            .joined(separator: ", ")
        return "지하철 노선 \(route.lineNames.joined(separator: "에서 ")), \(stationNames)"
    }
}
