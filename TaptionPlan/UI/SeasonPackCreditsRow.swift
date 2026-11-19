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
