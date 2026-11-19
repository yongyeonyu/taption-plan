import SwiftUI

/// 모든 이벤트 메뉴를 그리는 시트 하나. 제목·항목·입력 방식은 전부 매니페스트에서 오고, 앱은 무슨 이벤트인지 모른다.
public struct SeasonPackMenuView: View {
    private let center: SeasonPackCenter
    private let packID: String
    private let model: SeasonPackMenuModel
    private let language: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    public init(center: SeasonPackCenter = .shared, packID: String, menu: SeasonPackManifest.Menu, language: String) {
        self.center = center; self.packID = packID; self.language = language
        model = SeasonPackMenuModel(menu, language: language)
    }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(model.sections) { section in
                    Section(section.title ?? "") {
                        ForEach(section.items) { item in row(item) }
                    }
                }
            }
            .navigationTitle(model.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(SeasonPackText.ui("닫기", "Close", language: language)) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func row(_ item: SeasonPackMenuModel.Item) -> some View {
        switch item {
        case .text(_, let label, let text):
            VStack(alignment: .leading, spacing: 4) {
                if let label { Text(label).font(.footnote).foregroundStyle(.secondary) }
                Text(text)
            }
        case .memo(let id, let label, let maxLength, let readOnlyAfter):
            SeasonPackMemoView(center: center, packID: packID, itemID: id, label: label, maxLength: maxLength, readOnlyAfter: readOnlyAfter, language: language)
        case .credits:
            SeasonPackCreditsList(packs: center.packs, language: language)
        case .link(_, let label, let url):
            Button(label.isEmpty ? url.absoluteString : label) { openURL(url) }
        case .toggle(let id, let label):
            SeasonPackToggleRow(key: "seasonPack.toggle.\(packID).\(id)", label: label)
        }
    }
}

private struct SeasonPackToggleRow: View {
    let key: String
    let label: String
    @AppStorage private var isOn: Bool

    init(key: String, label: String) {
        self.key = key; self.label = label
        _isOn = AppStorage(wrappedValue: false, key)
    }

    var body: some View { Toggle(label, isOn: $isOn) }
}

/// 설치된 팩의 음원 출처(제목·만든이·라이선스·출처). 설정 화면의 「시즌 팩 음원 출처」도 이 뷰를 쓴다.
public struct SeasonPackCreditsList: View {
    private let entries: [(pack: String, license: SeasonPackManifest.AudioTrack.License, credits: [String])]
    private let language: String

    public init(packs: [SeasonPack], language: String) {
        self.language = language
        entries = packs.flatMap { pack in
            (pack.manifest.audio ?? []).map { (pack.id, $0.license, (pack.manifest.credits ?? []).map { $0.resolve(language: language) }) }
        }
    }

    public var body: some View {
        if entries.isEmpty {
            Text(SeasonPackText.ui("등록된 음원이 없습니다", "No music credits yet", language: language)).foregroundStyle(.secondary)
        } else {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.license.title).font(.subheadline.weight(.semibold))
                    Text("\(entry.license.creator) · \(entry.license.license)").font(.footnote).foregroundStyle(.secondary)
                    if let url = URL(string: entry.license.source), url.scheme?.lowercased() == "https" {
                        Link(entry.license.source, destination: url).font(.caption)
                    }
                }
            }
        }
    }
}

/// 설정 › 「시즌 팩 음원 출처」 화면.
public struct SeasonPackCreditsScreen: View {
    private let center: SeasonPackCenter
    private let language: String

    public init(center: SeasonPackCenter = .shared, language: String) { self.center = center; self.language = language }

    public var body: some View {
        List { SeasonPackCreditsList(packs: center.packs, language: language) }
            .navigationTitle(SeasonPackText.ui("시즌 팩 음원 출처", "Season pack music credits", language: language))
    }
}
