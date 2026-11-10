import SwiftUI

extension MapHomeView {
    /// 여행 모드 단추. 그 뒤에 가계부 화면 호스트를 붙인다(LED1111A03: ₩ 단추는 없애고 메모 목록·「+ 메모」에서 연다).
    var modeButtons: some View {
        travelModeButton.background { LedgerSheetHost(language: language, tripID: isTravelMode ? ledgerTripID : nil) }
    }

    /// 여행 모드에서 고른 날의 여행. 그 여행에 가계부 기록을 묶는다.
    var ledgerTripID: String? {
        let calendar = Calendar.autoupdatingCurrent
        return model.settings.travelPlanStops.first { $0.tripID != nil && calendar.isDate($0.day, inSameDayAs: model.selectedDate) }?.tripID
    }
}
