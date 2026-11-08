import SwiftUI

// 상세 화면(메모·고양이·추정·위치 타임라인·위젯 미리보기)이 함께 쓰는 조각.
// 화면 본체는 화면별 파일(MemoDetailView.swift 등)에 있다.

struct DetailHeader: View {
    let title: String
    let trailing: String
    var trailingColor: Color = .tpSecondary
    let action: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .font(.taption(size: 19, weight: .bold))
                .foregroundStyle(Color.tpInk)
            Spacer()
            Button(trailing, action: action)
                .font(.taption(size: 12, weight: .bold))
                .foregroundStyle(trailingColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(Color.tpCard)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.tpLine).frame(height: 0.5) }
    }
}

extension TravelMode {
    /// 추정 상세 지도와 위치 타임라인 경로 띠가 같이 쓰는 이동 색.
    var routeColor: Color {
        switch self {
        case .walking, .running, .cycling:
            Color.tpTransitDark
        case .bus, .taxi, .car:
            Color(red: 0.95, green: 0.77, blue: 0.44)
        case .subway, .train:
            Color(red: 0.56, green: 0.79, blue: 0.90)
        case .airplane:
            Color(red: 0.72, green: 0.66, blue: 0.92)
        case .ship:
            Color(red: 0.34, green: 0.67, blue: 0.76)
        }
    }
}

extension TimeSpan {
    /// 이 구간 안에서 `date`가 놓인 위치를 0...1로 자른 값.
    func clampedFraction(of date: Date) -> CGFloat {
        max(
            0,
            min(
                1,
                CGFloat(date.timeIntervalSince(start) / max(1, duration))
            )
        )
    }
}

extension Array {
    /// `span`과 겹치는 항목만 시작 시각 순으로 돌려준다.
    func overlapping(
        _ span: TimeSpan,
        by keyPath: KeyPath<Element, TimeSpan>
    ) -> [Element] {
        filter { $0[keyPath: keyPath].intersection(with: span) != nil }
            .sorted { $0[keyPath: keyPath].start < $1[keyPath: keyPath].start }
    }
}
