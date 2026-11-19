import SwiftUI

/// 홈 위쪽 공지 배너(ANN1119A01). 공지가 없으면 아무것도 그리지 않아 자리·간격이 생기지 않는다.
/// 배너는 가장 급한 1건이고, 누르면 지금 보이는 공지 전체를 시트로 보여 준다. 모달·강제 확인은 없다.
struct AnnouncementBanner: View {
    let language: MapHomeLanguage
    @State private var isSheetPresented = false
    private var service: AnnouncementService { .shared }

    var body: some View {
        if let item = service.visible.first {
            let code = AnnouncementPolicy.languageCode(language: language)
            HStack(spacing: 10) {
                Image(systemName: Self.symbol(item.kind)).foregroundStyle(Self.tint(item.kind))
                VStack(alignment: .leading, spacing: 2) {
                    Text(AnnouncementPolicy.title(of: item, code: code))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                        .foregroundStyle(Color.tpInk)
                        .lineLimit(1)
                    Text(AnnouncementPolicy.body(of: item, code: code))
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .regular))
                        .foregroundStyle(Color.tpSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { service.dismiss(item.id) } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.tpSecondary)
                .accessibilityLabel(language.text("닫기", "Close"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 2)
            .padding(.vertical, 2)
            .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            .padding(.horizontal, 16)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture { isSheetPresented = true }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .sheet(isPresented: $isSheetPresented) { AnnouncementSheet(language: language) }
        }
    }

    static func symbol(_ kind: AppAnnouncement.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .update: "sparkles"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }

    static func tint(_ kind: AppAnnouncement.Kind) -> Color {
        switch kind {
        case .info, .update: .tpAccent
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// 지금 보이는 공지를 정렬 순서로 모두 보여 주는 시트. 항목마다 전체 본문·「자세히」(https만)·닫기.
struct AnnouncementSheet: View {
    let language: MapHomeLanguage
    @Environment(\.dismiss) private var dismissSheet
    @Environment(\.openURL) private var openURL
    private var service: AnnouncementService { .shared }

    var body: some View {
        let code = AnnouncementPolicy.languageCode(language: language)
        let items = service.visible
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Label {
                                Text(AnnouncementPolicy.title(of: item, code: code))
                                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.label), weight: .semibold))
                            } icon: {
                                Image(systemName: AnnouncementBanner.symbol(item.kind)).foregroundStyle(AnnouncementBanner.tint(item.kind))
                            }
                            Text(AnnouncementPolicy.body(of: item, code: code))
                                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .regular))
                                .foregroundStyle(Color.tpSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 16) {
                                if let url = AnnouncementPolicy.link(of: item) {
                                    Button(language.text("자세히", "Details")) { openURL(url) }
                                }
                                Button(language.text("이 공지 닫기", "Dismiss")) { service.dismiss(item.id) }
                                    .foregroundStyle(Color.tpSecondary)
                            }
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .medium))
                        }
                        .accessibilityElement(children: .contain)
                    }
                    if items.isEmpty {
                        Text(language.text("새 공지가 없습니다", "No new announcements"))
                            .foregroundStyle(Color.tpSecondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(language.text("공지", "Announcements"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(language.text("닫기", "Close")) { dismissSheet() } }
            }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: items.isEmpty) { _, isEmpty in if isEmpty { dismissSheet() } }
    }
}

extension MapHomeView {
    /// 홈 위쪽 알림 칸: 공지 → 여행 계획 가져오기 순서.
    @ViewBuilder var homeTopNotices: some View {
        VStack(spacing: 8) {
            AnnouncementBanner(language: language)
            tripClipboardBanner
        }
    }
}
