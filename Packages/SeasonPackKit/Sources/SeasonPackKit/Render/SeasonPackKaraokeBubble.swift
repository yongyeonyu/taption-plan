import SwiftUI

/// 가사 큐 말풍선. 한 번에 하나, 지도 이동과 무관하게 화면 기준으로 붙는다. 저장되지 않는 일회성이라 스냅숏·백업·AI 기록에 남지 않는다.
struct SeasonPackKaraokeBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.black.opacity(0.85))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .overlay(alignment: .bottom) {
                Triangle().fill(.white).frame(width: 12, height: 7).offset(y: 6)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240)
            .transition(.opacity.combined(with: .scale(scale: 0.92)))
            .allowsHitTesting(false)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}
