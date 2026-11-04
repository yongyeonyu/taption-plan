import SwiftUI
import UIKit

extension ActionMemo {
    /// 고른 스티커 > 위치가 있으면 기본 메모 아이콘 > 화면별 기본 기호. 옛 기록은 바꾸지 않고 그릴 때만 고른다.
    func iconSymbol(fallback: String = "note.text") -> String {
        stickerSymbol ?? (mapPoint == nil ? fallback : StickerCatalog.defaultMemoSymbol)
    }

    var iconColorHex: String { stickerColorHex ?? StickerCatalog.defaultMemoColorHex }
}

/// 스티커 비트맵 캐시. 격자를 스크롤해도 같은 그림을 다시 그리지 않는다. 메모리가 부족하면 NSCache가 비운다.
@MainActor
enum StickerImageCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        return cache
    }()

    static func image(for entry: StickerEntry, tint: UInt32, side: CGFloat, scale: CGFloat) -> UIImage {
        let color = entry.isRecolorable ? tint : 0
        let key = "\(entry.id)#\(color)#\(Int(side))#\(Int(scale))" as NSString
        if let image = cache.object(forKey: key) { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let drawing = entry.drawing
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            StickerArtEngine.draw(drawing, style: entry.style, tint: tint, in: context.cgContext, side: side)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 저장된 스티커 값을 그린다. 목록에 없는 옛 이름은 SF Symbols로 두어 어떤 기록도 빈칸이 되지 않게 한다.
struct StickerGlyph: View {
    @Environment(\.displayScale) private var displayScale
    let symbol: String
    let colorHex: String
    var size: CGFloat = 24

    var body: some View {
        if let entry = resolvedEntry {
            Image(uiImage: StickerImageCache.image(
                for: entry,
                tint: StickerCatalog.tintValue(colorHex),
                side: size.rounded(.up),
                scale: displayScale
            ))
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
        }
    }

    private var resolvedEntry: StickerEntry? {
        if let entry = StickerCatalog.entry(for: symbol) { return entry }
        return UIImage(systemName: symbol) == nil ? StickerCatalog.entry(for: StickerCatalog.defaultSymbol) : nil
    }
}

/// 스티커 고르기. 한 번에 한 분류만 지연 격자로 그린다.
struct MapHomeStickerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var symbol: String
    @Binding var colorHex: String
    let language: MapHomeLanguage

    @State private var categoryID: String
    /// 최근 고른 스티커 id. 이 기기의 편의 기능이라 기록 데이터에 넣지 않는다.
    @AppStorage("mapHome.sticker.recent") private var recentStorage = ""

    private static let recentCategoryID = "recent"
    private static let recentLimit = 24

    init(symbol: Binding<String>, colorHex: Binding<String>, language: MapHomeLanguage) {
        _symbol = symbol
        _colorHex = colorHex
        self.language = language
        _categoryID = State(initialValue: StickerCatalog.entry(for: symbol.wrappedValue)?.categoryID
            ?? StickerCatalog.categories.first?.id ?? "")
    }

    private var recentEntries: [StickerEntry] {
        recentStorage.split(separator: ",").compactMap { StickerCatalog.entry(for: String($0)) }
    }

    private var entries: [StickerEntry] {
        if categoryID == Self.recentCategoryID { return recentEntries }
        return StickerCatalog.categories.first { $0.id == categoryID }?.entries ?? []
    }

    private var tabs: [(id: String, title: String)] {
        let recent = recentStorage.isEmpty ? [] : [(id: Self.recentCategoryID, title: language.text("최근", "Recent"))]
        return recent + StickerCatalog.categories.map { (id: $0.id, title: language.runtimeText($0.koreanName, $0.englishName)) }
    }

    private func choose(_ entry: StickerEntry) {
        symbol = entry.id
        let others = recentStorage.split(separator: ",").map(String.init).filter { $0 != entry.id }
        recentStorage = ([entry.id] + others).prefix(Self.recentLimit).joined(separator: ",")
    }

    private var selectedEntry: StickerEntry? { StickerCatalog.entry(for: symbol) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryTabs
                if selectedEntry?.isRecolorable == true {
                    colorRow
                }
                Divider()
                grid
            }
            .background(Color.tpBackground)
            .navigationTitle(language.text("스티커 고르기", "Choose a sticker"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("완료", "Done")) { dismiss() }
                }
            }
        }
    }

    private var categoryTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 6) {
                    ForEach(tabs, id: \.id) { category in
                        Button {
                            categoryID = category.id
                        } label: {
                            Text(category.title)
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold))
                                .foregroundStyle(categoryID == category.id ? Color.white : Color.tpInk)
                                .padding(.horizontal, 12)
                                .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
                                .background(
                                    categoryID == category.id ? Color.tpAccent : Color.tpSurface,
                                    in: Capsule()
                                )
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .id(category.id)
                        .accessibilityAddTraits(categoryID == category.id ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 12)
            }
            .frame(height: TaptionMenuMetrics.minimumHitSize + 12)
            .onAppear { proxy.scrollTo(categoryID, anchor: .center) }
        }
    }

    private var colorRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(Array(StickerCatalog.colors.enumerated()), id: \.element) { index, color in
                    Button {
                        colorHex = color
                    } label: {
                        Circle()
                            .fill(Color(hex: color))
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().stroke(Color.black, lineWidth: colorHex == color ? 3 : 1.2)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(language.text("색 \(index + 1)", "Color \(index + 1)"))
                    .accessibilityAddTraits(colorHex == color ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
        }
        .frame(height: 44)
        .accessibilityIdentifier("sticker-color-row")
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(entries) { entry in
                    cell(entry)
                }
            }
            .padding(12)
        }
        // 분류를 바꾸면 격자를 새로 만들어 맨 위부터 보여 준다.
        .id(categoryID)
    }

    private func cell(_ entry: StickerEntry) -> some View {
        Button {
            choose(entry)
        } label: {
            StickerGlyph(symbol: entry.id, colorHex: colorHex, size: 52)
                .frame(maxWidth: .infinity)
                .frame(height: 68)
                // 어두운 화면에서도 검은 테두리가 보이도록 칸 바탕은 밝은색으로 고정한다.
                .background(Color(hex: "#FFF9EC"), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(symbol == entry.id ? Color.tpAccent : Color.clear, lineWidth: 3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(language.runtimeText(entry.koreanName, entry.englishName))
        .accessibilityAddTraits(symbol == entry.id ? .isSelected : [])
    }
}
