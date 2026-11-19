import SeasonPackKit
import SwiftUI

/// 설정 › 내 데이터 아래의 「시즌 팩 음원 출처」(SEA1119A01). 화면은 패키지가 그린다.
struct SeasonPackCreditsRow: View {
    let language: MapHomeLanguage
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            HStack {
                Text(language.text("시즌 팩 음원 출처", "Season pack music credits"))
                Spacer()
                Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            NavigationStack { SeasonPackCreditsScreen(language: AnnouncementPolicy.languageCode(language: language)) }
        }
    }
}

/// 설정 › 내 데이터 아래의 「시즌 팩 업데이트」 상태 줄(SEA1119A01): 받는 중 진행률·중단·실패를 보여 준다. 문구는 패키지가 ko/en으로 준다.
struct SeasonPackUpdateRow: View {
    let language: MapHomeLanguage

    var body: some View {
        let center = SeasonPackCenter.shared
        HStack {
            Text(language.text("시즌 팩 업데이트", "Season pack updates"))
            Spacer()
            Text(center.downloadStatus.label(language: AnnouncementPolicy.languageCode(language: language)))
                .font(.footnote).foregroundStyle(.secondary)
            if case .downloading(let received, let total) = center.downloadStatus, total > 0 {
                ProgressView(value: Double(received), total: Double(total)).frame(width: 44)
            }
        }
    }
}
