import Foundation

/// 스티커 한 장. 저장되는 값은 `id` 문자열뿐이라 그림을 다듬어도 옛 기록은 그대로 열린다.
struct StickerEntry: Identifiable, Sendable {
    let id: String
    let koreanName: String
    let englishName: String
    let style: StickerStyle
    let source: String
    let categoryID: String

    var isRecolorable: Bool { style.isRecolorable }
    var drawing: StickerArtEngine.Drawing { StickerArtEngine.parse(source, parts: StickerCatalog.parts) }
}

struct StickerCategory: Identifiable, Sendable {
    let id: String
    let koreanName: String
    let englishName: String
    let entries: [StickerEntry]
}

/// 분류별 스티커 목록. 처음 쓸 때 한 번 읽고, 그림 층은 실제로 그릴 때 해석한다.
enum StickerCatalog {
    static let defaultSymbol = "star.fill"
    static let defaultColorHex = "#F28FA9"
    /// 위치가 있는 메모가 스티커를 고르지 않았을 때 쓰는 기본 아이콘.
    static let defaultMemoSymbol = "basic.memo"
    static let defaultMemoColorHex = "#F2D58D"
    /// 앞 6개는 예전 고르기 색이라 순서를 유지한다.
    static let colors = [
        "#F28FA9", "#A9CFF0", "#8FD9C5", "#F2D58D", "#C2B4E9", "#F2B18D",
        "#E8655F", "#F39A4A", "#F9D65C", "#7CC46F", "#5BA8E5", "#9C7FD6",
        "#A9744F", "#FFFFFF", "#B9BEC6", "#5A5560"
    ]

    static let categories: [StickerCategory] = sources.map { category in
        StickerCategory(
            id: category.id,
            koreanName: category.ko,
            englishName: category.en,
            entries: parseEntries(category.source, categoryID: category.id)
        )
    }

    private static let index: [String: StickerEntry] = {
        var result: [String: StickerEntry] = [:]
        for category in categories {
            for entry in category.entries where result[entry.id] == nil { result[entry.id] = entry }
        }
        return result
    }()

    static func entry(for id: String) -> StickerEntry? { index[id] }

    /// 저장된 `#RRGGBB`를 그리기용 값으로 읽는다. 읽지 못하면 기본색으로 그린다.
    static func tintValue(_ hex: String) -> UInt32 {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return UInt32(digits, radix: 16) ?? UInt32(defaultColorHex.dropFirst(), radix: 16) ?? 0
    }

    static let parts: [String: String] = {
        var result: [String: String] = [:]
        for line in partsSource.split(separator: "\n") {
            let fields = line.split(separator: "|", maxSplits: 1)
            if fields.count == 2 { result[String(fields[0])] = String(fields[1]) }
        }
        return result
    }()

    /// `id|한글|English|m·c·d|그림`. `#`으로 시작하는 줄은 주석이다.
    static func parseEntries(_ source: String, categoryID: String) -> [StickerEntry] {
        source.split(separator: "\n").compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, let style = StickerStyle(rawValue: String(fields[3])) else { return nil }
            return StickerEntry(
                id: String(fields[0]),
                koreanName: String(fields[1]),
                englishName: String(fields[2]),
                style: style,
                source: String(fields[4]),
                categoryID: categoryID
            )
        }
    }
}
