import CryptoKit
import Foundation
import Security
@_exported import TaptionAssistantKit

extension MapHomeView {
    /// 앱을 열 때 확인한다. 처음 보는 계획이 있으면 여행 모드로 바꿔 미리보기를 띄운다.
    func checkTripRelay() async {
        // AI 화면이 앱 비밀번호로 승인할 수 있게 한다(PIN1110A01).
        model.connectAssistantAppPassword()
        // 주 키는 앱이 만들어 등록하고, 이번 배포에서 한 번 바꾼다(SEC1110A02).
        guard await AssistantRegistration.ensureReady() else { return }
        // AI 비서 명령도 같은 때 받는다(TRP1110A07).
        await checkAssistantCommands()
        guard TripRelay.isAvailable, TripRelay.key != nil, !isTripImportPresented,
              let text = await TripRelay.fetch(), !isTripImportPresented, TripRelay.isNew(text) else { return }
        pastedTripText = text
        if isTripClipboardOfferVisible { isTripClipboardOfferVisible = false }
        isTravelMode = true
        isTripImportPresented = true
    }
}
