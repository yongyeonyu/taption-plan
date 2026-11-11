import SwiftUI

/// Siri·단축어 「화면 열기」(SIR1111A01): 홈 화면이 받아 가계부·AI 목록·메모·하루 카드·달력을 연다.
extension MapHomeView {
    func openSiriScreen() {
        guard let screen = SiriNavigation.take() else { return }
        switch screen {
        case .ledger:
            LedgerPresenter.shared.isPresented = true
        case .aiTasks, .memos:
            memoLedgerFilter = screen == .aiTasks ? .ai : .memos
            withAnimation(.snappy) { memoStackExpanded = true }
        case .dayCard:
            isDailyCardPresented = true
        case .calendar:
            isCalendarPresented = true
        }
    }
}

extension View {
    /// 홈 화면이 나타날 때와 Siri 요청이 올 때 `action`을 부른다.
    func onSiriScreenRequest(_ action: @escaping () -> Void) -> some View {
        onAppear(perform: action)
            .onReceive(NotificationCenter.default.publisher(for: SiriNavigation.notification)) { _ in action() }
    }
}
