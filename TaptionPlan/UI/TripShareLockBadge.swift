import SwiftUI
import TaptionTripShare

// 묶음 B가 채운다(TSH1114A26). 0단계는 컴파일되는 뼈대와 아래 약속만 둔다.
//
// 0단계가 약속한 것
// - 잠금은 `TripShareStore.shared.lockState(tripID:itemID:)`로 읽는다(그 일정의 잠금과 그날 묶음의 잠금을 함께 본다).
//   `.other(by:until:)`이면 `store.names(tripID:)?.name(.member(by))`로 「○○ 고치는 중」을 만든다.
// - 공유하지 않는 여행·잠기지 않은 칸에서는 아무것도 그리지 않는다.
//
// B가 할 일: 배지 그림, 그리고 `TravelPlanTable`의 블록·`TravelCourseView`의 카드에 이 배지를 놓기(그 두 파일은 B가 고친다).

/// 계획표 블록·코스 카드 위의 「○○ 고치는 중」.
struct TripShareLockBadge: View {
    let tripID: String
    let itemID: String
    let language: MapHomeLanguage

    var body: some View {
        EmptyView()
    }
}
