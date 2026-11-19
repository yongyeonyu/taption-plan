import Foundation

/// 공유 확장이 App Group 보관함에 둔 항공 알림·탑승권을 앱이 읽어 일정 칸에 반영한다(FLT1119A01).
/// 처리한 항목은 모두 지운다(읽지 못한 것도 지운다: 남겨 두면 계속 쌓인다). 여행이 없어 못 붙인 글은 `FlightInbox`가 이어서 보관한다.
@MainActor
enum FlightShareIntake {
    /// 보관함을 비운다. 마지막으로 의미 있는 결과(후보 확인 > 붙임 > 보류 > 못 읽음 순)를 화면 알림 센터에 알린다.
    static func drain(into model: AppModel, now: Date = .now, container: URL? = nil) async {
        guard model.isBootstrapped else { return }
        let entries = FlightShareStore.pending(now: now, container: container)
        guard !entries.isEmpty else { return }
        var best: FlightIngest.Reply?
        for entry in entries {
            let text: String?
            switch entry.kind {
            case .text: text = entry.text
            case .pass: text = FlightShareStore.passData(for: entry, container: container).flatMap(FlightPassReader.text(from:))
            }
            guard let text else { best = better(best, .unreadable); continue }
            best = better(best, await model.ingestFlightAlert(text, source: .share, now: entry.at))
        }
        FlightShareStore.remove(entries.map(\.id), now: now, container: container)
        if let best { FlightAlertCenter.shared.show(best) }
    }

    /// 두 결과 가운데 사용자가 먼저 알아야 할 것.
    static func better(_ current: FlightIngest.Reply?, _ next: FlightIngest.Reply) -> FlightIngest.Reply {
        guard let current else { return next }
        func rank(_ reply: FlightIngest.Reply) -> Int {
            switch reply {
            case .needsConfirmation: 5
            case .attached, .prepAdded: 4
            case .noTrip: 3
            case .deferred, .lookupFailed: 2
            case .unreadable: 1
            }
        }
        return rank(next) > rank(current) ? next : current
    }
}
