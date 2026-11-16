import SwiftUI
import TaptionPlanCore

extension MapHomeView {
    /// 왼쪽 위 여행 모드 단추(LED1111A03: ₩ 단추는 없애고 메모 목록·「+ 메모」에서 가계부를 연다).
    var modeButtons: some View { travelModeButton }

    /// 가계부 화면 호스트. 지도 앞 층에 늘 둔다(하단 막대·왼쪽 위 단추는 화면에 따라 숨는다).
    var ledgerSheetHost: some View {
        LedgerSheetHost(language: language, tripID: nil, model: model)
    }

    /// 화면이 앞에 있고 가계부가 홈을 덮고 있지 않을 때만 홈의 화면용 갱신을 돌린다(LGS1115A01).
    var isHomeLive: Bool {
        MapHomeCoverSet.isHomeLive(isSceneActive: scenePhase == .active, isCovered: MapHomeLiveGate.shared.isCovered)
    }

    /// 홈이 읽는 최신 위치. 덮인 동안은 덮이기 직전 값을 돌려줘 위치가 올 때마다 홈이 다시 그려지지 않는다.
    var homeLatestReading: SensorReading? {
        work.heldLatestReading.read(isCovered: MapHomeLiveGate.shared.isCovered) { model.latestSensorReading }
    }

    /// 홈이 읽는 실시간 경로. `homeLatestReading`과 같은 규칙.
    var homeLiveRoute: LiveRouteState {
        work.heldLiveRoute.read(isCovered: MapHomeLiveGate.shared.isCovered) { model.liveRouteState }
    }
}
