import SwiftUI
import TaptionTripShare

// 잠금 배지(TSH1114A26 묶음 B).
// - 잠금은 `TripShareStore.shared.lockState(tripID:itemID:)`로 읽는다(그 일정의 잠금과 그날 묶음의 잠금을 함께 본다).
// - 공유하지 않는 여행·잠기지 않은 칸·내가 잡은 칸에서는 아무것도 그리지 않는다.
// - 기한이 지난 잠금은 서버가 따로 알리지 않으므로, 기한에 맞춰 한 번 다시 그린다.

/// 계획표 블록·코스 카드 위의 「○○ 고치는 중」.
struct TripShareLockBadge: View {
    let tripID: String
    let itemID: String
    let language: MapHomeLanguage
    /// 좁은 칸(계획표 블록)에서는 연필 그림만 보인다.
    var isCompact = false

    /// 기한이 지나 다시 그릴 때 바뀌는 값.
    @State private var expiredUntil = 0

    var body: some View {
        let store = TripShareStore.shared
        if case .other(let by, let until) = store.lockState(tripID: tripID, itemID: itemID), until != expiredUntil {
            let label = TripSharePlanText.editing(store.names(tripID: tripID)?.name(.member(by)) ?? "", language)
            Group {
                if isCompact {
                    Image(systemName: "pencil.circle.fill").font(.system(size: 13)).background(Color.white, in: Circle())
                } else {
                    Label(label, systemImage: "pencil").font(.caption2.weight(.medium)).lineLimit(1)
                        .padding(.horizontal, 7).frame(height: 22)
                        .background(TravelInk.actual.opacity(0.14), in: Capsule())
                }
            }
            .foregroundStyle(TravelInk.actual)
            .accessibilityLabel(label)
            .accessibilityIdentifier("travelShareLock-\(itemID)")
            .task(id: until) {
                let wait = Double(until) / 1000 - Date.now.timeIntervalSince1970
                if wait > 0 { try? await Task.sleep(for: .seconds(wait + 0.2)) }
                if !Task.isCancelled { expiredUntil = until }
            }
        }
    }
}
