import SwiftUI

/// 사이드바 옆 구글 일정·메모·스티커를 눌렀을 때 왼쪽 말풍선에 보여 줄 내용(SBN1102A01).
struct MapHomeSidebarNote: Equatable {
    enum Source: Equatable {
        case event
        case memo(UUID)
        case sticker(UUID)
    }

    let id: String
    let source: Source
    let title: String
    let time: String
    var detail: String? = nil
    let minute: Int
    let badgeOffset: CGFloat

    private static func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    static func event(id: String, title: String, span: TimeSpan, minute: Int, badgeOffset: CGFloat) -> Self {
        Self(id: "event-\(id)", source: .event, title: title, time: "\(clock(span.start))–\(clock(span.end))", minute: minute, badgeOffset: badgeOffset)
    }

    static func memo(_ memo: ActionMemo, minute: Int, badgeOffset: CGFloat) -> Self {
        Self(id: "memo-\(memo.id)", source: .memo(memo.id), title: memo.text, time: clock(memo.occurredAt), minute: minute, badgeOffset: badgeOffset)
    }

    static func sticker(_ sticker: MapSticker, minute: Int, badgeOffset: CGFloat) -> Self {
        Self(id: "sticker-\(sticker.id)", source: .sticker(sticker.id), title: sticker.title, time: clock(sticker.occurredAt), detail: sticker.memo, minute: minute, badgeOffset: badgeOffset)
    }

    /// 말풍선을 눌러 편집 창을 열 수 있는지. 구글 일정은 앱에서 고치지 않는다.
    var editorTarget: MapHomeStickerEditorTarget? {
        switch source {
        case .event: nil
        case let .memo(id): .memo(id)
        case let .sticker(id): .sticker(id)
        }
    }
}

enum MapHomeSidebarNoteLayout {
    static let width: CGFloat = 190
    static let badgeRadius: CGFloat = 11
    static let gap: CGFloat = 8
    static let visibleSeconds: UInt64 = 6

    /// 아이콘 왼쪽에 말풍선 오른쪽 끝이 오도록 중심 x를 정한다.
    static func centerX(badgeX: CGFloat) -> CGFloat {
        badgeX - badgeRadius - gap - width / 2
    }
}

struct MapHomeSidebarNoteBubble: View {
    let note: MapHomeSidebarNote
    let onExpire: () -> Void
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if note.source == .event {
                        Image("GoogleGLogo").resizable().scaledToFit().frame(width: 12, height: 12)
                    }
                    Text(note.time)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                        .monospacedDigit()
                }
                Text(note.title)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .bold, design: .rounded))
                    .foregroundStyle(Color.tpInk)
                    .lineLimit(3)
                if let detail = note.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(3)
                }
            }
            .frame(width: MapHomeSidebarNoteLayout.width - 20, alignment: .leading)
            .padding(10)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.tpLine, lineWidth: 0.8))
            .overlay(alignment: .trailing) {
                // 아이콘 쪽을 가리키는 꼬리
                Rectangle()
                    .fill(Color.tpSurface)
                    .frame(width: 9, height: 9)
                    .rotationEffect(.degrees(45))
                    .offset(x: 4)
            }
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(note.time) \(note.title)")
        .task(id: note.id) {
            try? await Task.sleep(nanoseconds: MapHomeSidebarNoteLayout.visibleSeconds * 1_000_000_000)
            if !Task.isCancelled { onExpire() }
        }
    }
}
