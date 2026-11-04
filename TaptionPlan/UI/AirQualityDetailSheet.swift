import SwiftUI
import UIKit
import MapKit

struct AirQualityDetailSheet: View {
    let weather: WeatherContext
    let airQuality: AirQualityContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: weather.symbolName)
                            .font(.taption(size: 25, weight: .semibold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                weatherSymbolColor(weather, component: .primary),
                                weatherSymbolColor(weather, component: .secondary)
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(weather.condition) · \(AppRegion.current.temperature(celsius: weather.temperatureCelsius))°")
                                .font(.taption(size: 18, weight: .bold))
                            Text("통합 미세먼지 \(airQuality.overallGrade.displayName)")
                                .font(.taption(size: 14, weight: .semibold))
                                .foregroundStyle(airQuality.overallGrade.displayColor)
                        }
                    }

                    HStack(spacing: TaptionSpacing.snug) {
                        Image(systemName: weather.isStale == true
                            ? "clock.arrow.circlepath"
                            : "checkmark.circle.fill")
                        Text(
                            weather.isStale == true
                                ? "마지막 확인 · \(weather.freshnessLabel)"
                                : "\(weather.freshnessLabel)"
                        )
                    }
                    .font(.taption(size: 11, weight: .semibold))
                    .foregroundStyle(
                        weather.isStale == true
                            ? Color.orange
                            : Color.tpSecondary
                    )

                    HStack(spacing: 10) {
                        pollutantCard(
                            title: "PM10",
                            value: airQuality.pm10MicrogramsPerCubicMeter,
                            grade: airQuality.pm10Grade
                        )
                        pollutantCard(
                            title: "PM2.5",
                            value: airQuality.pm25MicrogramsPerCubicMeter,
                            grade: airQuality.pm25Grade
                        )
                    }

                    VStack(alignment: .leading, spacing: TaptionSpacing.regular) {
                        detailRow(
                            "관측 시각",
                            airQuality.observedAt.formatted(
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                        if let stationName = airQuality.stationName {
                            detailRow("측정소", stationName)
                        }
                        detailRow("제공원", airQuality.providerName)
                        if airQuality.isFallback {
                            Label(
                                "대체 자료",
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                            .font(.taption(size: 12, weight: .semibold))
                            .foregroundStyle(Color.tpSecondary)
                        }
                    }
                    .padding(14)
                    .background(
                        Color.tpBackground,
                        in: RoundedRectangle(cornerRadius: TaptionRadius.card)
                    )

                    WeatherAttributionView()
                }
                .padding(18)
            }
            .navigationTitle("날씨 · 미세먼지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    private func pollutantCard(
        title: String,
        value: Double,
        grade: AirQualityGrade
    ) -> some View {
        VStack(alignment: .leading, spacing: TaptionSpacing.snug) {
            Text(title)
                .font(.taption(size: 13, weight: .semibold))
                .foregroundStyle(Color.tpSecondary)
            Text("\(Int(value.rounded())) μg/m³")
                .font(.taption(size: 18, weight: .bold))
            Text(grade.displayName)
                .font(.taption(size: 12, weight: .bold))
                .foregroundStyle(grade.displayColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.tpBackground, in: RoundedRectangle(cornerRadius: TaptionRadius.card))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(Color.tpSecondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.taption(size: 13, weight: .medium))
    }
}

private extension AirQualityGrade {
    var displayColor: Color {
        switch self {
        case .good: Color(red: 0.20, green: 0.55, blue: 0.84)
        case .moderate: Color(red: 0.22, green: 0.62, blue: 0.34)
        case .bad: Color(red: 0.92, green: 0.55, blue: 0.12)
        case .veryBad: Color(red: 0.86, green: 0.20, blue: 0.20)
        }
    }
}
