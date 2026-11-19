import Foundation

/// 아이콘이 여는 메뉴를 화면용으로 푼 값. 모르는 `kind`는 그 항목만 빠지고, `link`는 https만 남는다.
public struct SeasonPackMenuModel: Sendable, Equatable {
    public enum Item: Sendable, Equatable, Identifiable {
        case text(id: String, label: String?, text: String)
        case memo(id: String, label: String, maxLength: Int, readOnlyAfter: String?)
        case credits(id: String, label: String)
        case link(id: String, label: String, url: URL)
        case toggle(id: String, label: String)

        public var id: String {
            switch self {
            case .text(let id, _, _), .memo(let id, _, _, _), .credits(let id, _), .link(let id, _, _), .toggle(let id, _): id
            }
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var id: Int
        public var title: String?
        public var items: [Item]
    }

    public var title: String
    public var sections: [Section]

    public var isEmpty: Bool { sections.allSatisfy { $0.items.isEmpty } }

    public init(_ menu: SeasonPackManifest.Menu, language: String) {
        title = menu.title?.resolve(language: language) ?? ""
        sections = menu.sections.enumerated().map { index, section in
            Section(id: index, title: section.title?.resolve(language: language), items: section.items.compactMap { Self.item($0, language: language) })
        }.filter { !$0.items.isEmpty }
    }

    static func item(_ raw: SeasonPackManifest.Menu.Item, language: String) -> Item? {
        guard SeasonPackValidation.isKeyName(raw.id) else { return nil }
        let label = raw.label?.resolve(language: language) ?? ""
        switch raw.kind {
        case "text":
            guard let text = raw.text?.resolve(language: language), !text.isEmpty else { return nil }
            return .text(id: raw.id, label: label.isEmpty ? nil : label, text: text)
        case "memo":
            return .memo(id: raw.id, label: label, maxLength: raw.maxLength ?? 200, readOnlyAfter: raw.readOnlyAfter)
        case "credits":
            return .credits(id: raw.id, label: label)
        case "link":
            guard let text = raw.url, text.count <= 300, let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return .link(id: raw.id, label: label, url: url)
        case "toggle":
            return .toggle(id: raw.id, label: label)
        default:
            return nil
        }
    }
}
