import MapKit
import SwiftUI
import TaptionPlanCore

/// 표시 메뉴의 「오프라인 지도」 행(MAP1108A02). 누를 때 보이던 벡터 지도 영역을 시트로 넘긴다.
struct MapHomeOfflineMapMenuRow: View {
    let language: MapHomeLanguage
    let visibleRegion: () -> MKCoordinateRegion?

    @State private var presentedRegion: PresentedRegion?

    private struct PresentedRegion: Identifiable {
        let id = UUID()
        let region: MKCoordinateRegion?
    }

    var body: some View {
        Button {
            presentedRegion = PresentedRegion(region: visibleRegion())
        } label: {
            HStack(spacing: 8) {
                Label(language.text("오프라인 지도", "Offline map"), systemImage: "arrow.down.circle")
                    .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold))
                    .foregroundStyle(Color.tpInk)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Color.tpAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(item: $presentedRegion) { item in
            MapHomeOfflineMapSheet(language: language, region: item.region)
        }
    }
}

struct MapHomeOfflineMapSheet: View {
    let language: MapHomeLanguage
    let region: MKCoordinateRegion?

    @Environment(\.dismiss) private var dismiss
    @State private var controller = OfflineVectorMapController.shared
    @State private var minZoom = 8
    @State private var maxZoom = 14
    @State private var isDeleteConfirmPresented = false

    private var plan: OfflineVectorDownloadPlan? {
        guard let region else { return nil }
        let bounds = OfflineVectorBounds(
            centerLatitude: region.center.latitude,
            centerLongitude: region.center.longitude,
            latitudeDelta: region.span.latitudeDelta,
            longitudeDelta: region.span.longitudeDelta
        )
        return OfflineVectorDownloadPlan(bounds: bounds, zooms: minZoom...maxZoom)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minZoom, in: 0...maxZoom) {
                        Text(language.text("최소 확대 \(minZoom)", "Min zoom \(minZoom)"))
                    }
                    Stepper(value: $maxZoom, in: minZoom...OfflineVectorLimits.standard.maxZoom) {
                        Text(language.text("최대 확대 \(maxZoom)", "Max zoom \(maxZoom)"))
                    }
                } header: {
                    Text(language.text("지금 보이는 지도 영역", "Visible map area"))
                } footer: {
                    Text(estimateText)
                }

                Section {
                    downloadControls
                }

                Section {
                    Text(storedText)
                    Button(role: .destructive) {
                        isDeleteConfirmPresented = true
                    } label: {
                        Text(language.text("오프라인 지도 삭제", "Delete offline map"))
                    }
                    .disabled(controller.summary.bytes == 0)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language.text(
                            "최대 300MB. 넘으면 오래 안 쓴 타일부터 지웁니다. 벡터 지도 전용이며 애플 지도는 저장하지 않습니다.",
                            "Up to 300MB; least-used tiles go first. Vector maps only; Apple Maps is never stored."
                        ))
                        Text(verbatim: "OpenFreeMap · © OpenMapTiles · © OpenStreetMap")
                    }
                }
            }
            .navigationTitle(language.text("오프라인 지도", "Offline map"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("닫기", "Close")) { dismiss() }
                }
            }
            .confirmationDialog(
                language.text("저장한 오프라인 지도를 모두 지울까요?", "Delete all saved offline maps?"),
                isPresented: $isDeleteConfirmPresented,
                titleVisibility: .visible
            ) {
                Button(language.text("삭제", "Delete"), role: .destructive) {
                    Task { await controller.deleteAll() }
                }
            }
            .task { await controller.refreshSummary() }
        }
    }

    @ViewBuilder
    private var downloadControls: some View {
        switch controller.phase {
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text(language.text("받는 중 \(done)/\(total)", "Downloading \(done)/\(total)"))
            }
            Button(language.text("취소", "Cancel"), role: .cancel) { controller.cancel() }
        default:
            if let status = statusText {
                Text(status).foregroundStyle(.secondary)
            }
            Button(language.text("다운로드", "Download")) {
                if let plan { controller.start(plan) }
            }
            .disabled(plan == nil || plan?.problem != nil)
        }
    }

    private var estimateText: String {
        guard let plan else {
            return language.text("벡터 지도를 연 뒤 다시 열어 주세요.", "Open a vector map style first.")
        }
        let size = Self.megabytes(plan.estimatedBytes)
        let count = plan.tileCount.formatted()
        let estimate = language.text("예상 \(size) · 타일 \(count)개", "About \(size) · \(count) tiles")
        guard plan.problem != nil else { return estimate }
        return estimate + "\n" + language.text(
            "한 번에 3,000개·50MB까지입니다. 지도를 확대하거나 최대 확대를 낮춰 주세요.",
            "Limit is 3,000 tiles or 50MB. Zoom in or lower max zoom."
        )
    }

    private var storedText: String {
        let size = Self.megabytes(controller.summary.bytes)
        let count = controller.summary.tiles.formatted()
        return language.text("저장됨 \(size) · 타일 \(count)개", "Saved \(size) · \(count) tiles")
    }

    private var statusText: String? {
        switch controller.phase {
        case .finished(let outcome) where outcome.reachedByteCap:
            language.text("50MB에 닿아 멈췄습니다.", "Stopped at 50MB.")
        case .finished(let outcome) where outcome.failed > 0:
            language.text("일부를 받지 못했습니다. 다시 누르면 이어 받습니다.", "Some tiles failed. Tap again to resume.")
        case .finished:
            language.text("다운로드 완료", "Download complete")
        case .cancelled:
            language.text("취소했습니다. 다시 누르면 이어 받습니다.", "Cancelled. Tap again to resume.")
        case .failed:
            language.text("다운로드하지 못했습니다.", "Download failed.")
        case .idle, .downloading:
            nil
        }
    }

    private static func megabytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
