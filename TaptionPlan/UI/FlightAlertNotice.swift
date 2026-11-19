import SwiftUI

/// 항공 알림을 읽은 결과를 홈 위쪽에 잠깐 알린다(FLT1119A01). 후보 카드가 둘 이상이면 어느 카드에 붙일지 묻는다.
/// 원문(이름·예약번호가 든 글)은 화면에 보이지 않는다. 결과 문구와 카드 제목·날짜만 보인다.
struct FlightAlertNotice: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage
    private let center = FlightAlertCenter.shared

    var body: some View {
        Group {
            if let message = center.message {
                HStack(spacing: 10) {
                    Image(systemName: "airplane").foregroundStyle(Color.tpInk)
                    Text(message)
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { center.clearMessage() } label: {
                        Image(systemName: "xmark").frame(width: 32, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tpSecondary)
                    .accessibilityLabel(language.text("닫기", "Close"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("flightAlertNotice")
            }
        }
        .confirmationDialog(
            language.text("어느 카드에 붙일까요?", "Which card should this go to?"),
            isPresented: Binding(get: { center.confirmation != nil }, set: { if !$0 { center.confirmation = nil } }),
            titleVisibility: .visible, presenting: center.confirmation
        ) { request in
            ForEach(request.candidates) { candidate in
                Button(candidate.dateText.isEmpty ? candidate.title : "\(candidate.title) · \(candidate.dateText)") { resolve(request, cardID: candidate.cardID) }
            }
            if request.allowsNew { Button(language.text("새 카드로 만들기", "Create a new card")) { resolve(request, cardID: nil) } }
            Button(language.text("취소", "Cancel"), role: .cancel) {}
        }
    }

    private func resolve(_ request: FlightIngest.Confirmation, cardID: String?) {
        center.confirmation = nil
        Task { @MainActor in center.show(await model.resolveFlightConfirmation(request, attachTo: cardID)) }
    }
}
