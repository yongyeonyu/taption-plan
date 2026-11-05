import SwiftUI
import UIKit
import MapKit

extension TimelineDetailPanel {
    func travelModeEditor(for travel: TravelSegment) -> some View {
        HStack(spacing: TaptionSpacing.regular) {
            Label(
                routeModeName(travel.mode),
                systemImage: routeModeSystemImage(travel.mode)
            )
            .font(.taption(size: 9, weight: .bold))
            .foregroundStyle(Color.tpInk)

            Text(
                "\(travel.span.start.formatted(date: .omitted, time: .shortened))–\(travel.span.end.formatted(date: .omitted, time: .shortened))"
            )
            .font(.taption(size: 8))
            .foregroundStyle(Color.tpSecondary)

            Spacer(minLength: 4)

            Menu {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Button {
                        model.confirmTravel(travel.id, mode: mode)
                    } label: {
                        Label(
                            routeModeName(mode),
                            systemImage: routeModeSystemImage(mode)
                        )
                    }
                }
            } label: {
                Label("이동수단 변경", systemImage: "pencil")
                    .font(.taption(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.tpPrimaryFill, in: Capsule())
            }
            .accessibilityLabel("이동수단 변경")
            .accessibilityValue(routeModeName(travel.mode))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.tpSurfaceCream, in: RoundedRectangle(cornerRadius: TaptionRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: TaptionRadius.control)
                .stroke(Color.tpLine, lineWidth: 0.7)
        }
    }
}
