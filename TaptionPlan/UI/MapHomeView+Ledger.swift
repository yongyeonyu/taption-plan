import SwiftUI

extension MapHomeView {
    /// 여행 모드 단추와 그 옆 가계부 단추(LED1110A01).
    @ViewBuilder var modeButtons: some View {
        travelModeButton
        LedgerCircleButton(language: language, tripID: isTravelMode ? ledgerTripID : nil)
    }

    /// 여행 모드에서 고른 날의 여행. 그 여행에 가계부 기록을 묶는다.
    var ledgerTripID: String? {
        let calendar = Calendar.autoupdatingCurrent
        return model.settings.travelPlanStops.first { $0.tripID != nil && calendar.isDate($0.day, inSameDayAs: model.selectedDate) }?.tripID
    }
}

/// 왼쪽 위 가계부 단추. 누르면 가계부 화면이 열린다.
struct LedgerCircleButton: View {
    let language: MapHomeLanguage
    var tripID: String?
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            TaptionBarIcon(systemImage: language == .korean ? "wonsign" : "dollarsign", size: 23)
                .frame(width: 40, height: 40)
                .background { TaptionStickerDisc() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.text("가계부", "Ledger"))
        .accessibilityIdentifier("mapHome.ledger")
        .sheet(isPresented: $isPresented) { LedgerSheet(language: language, tripID: tripID) }
    }
}
