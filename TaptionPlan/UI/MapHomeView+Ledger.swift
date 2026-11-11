import SwiftUI

extension MapHomeView {
    /// 왼쪽 위 여행 모드 단추(LED1111A03: ₩ 단추는 없애고 메모 목록·「+ 메모」에서 가계부를 연다).
    var modeButtons: some View { travelModeButton }

    /// 가계부 화면 호스트. 지도 앞 층에 늘 둔다(하단 막대·왼쪽 위 단추는 화면에 따라 숨는다).
    var ledgerSheetHost: some View {
        let stops = model.settings.travelPlanStops, items = model.settings.travelTripItems ?? []
        return LedgerSheetHost(language: language, tripID: isTravelMode ? ledgerTripID : nil) {
            LedgerBook.plannedTrips(stops: stops, items: items)
        }
    }

    /// 여행 모드에서 고른 날의 여행. 그 여행에 가계부 기록을 묶는다.
    var ledgerTripID: String? {
        let calendar = Calendar.autoupdatingCurrent
        return model.settings.travelPlanStops.first { $0.tripID != nil && calendar.isDate($0.day, inSameDayAs: model.selectedDate) }?.tripID
    }
}
