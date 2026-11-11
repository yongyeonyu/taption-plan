import SwiftUI

/// GPS 로그만 GPX로 내보내 공유하는 줄(PLN1111A01). 기간을 고르면 파일을 만들고 공유 단추가 나온다.
struct GPXExportCard: View {
    let model: AppModel
    let language: MapHomeLanguage
    @State private var status = ""
    @State private var file: URL?
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Menu {
                    Button(language.text("오늘", "Today")) { export(days: 1) }
                    Button(language.text("최근 7일", "Last 7 days")) { export(days: 7) }
                    Button(language.text("최근 30일", "Last 30 days")) { export(days: 30) }
                } label: {
                    Label(language.text("기간 고르기", "Choose period"), systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                        .lineLimit(1)
                }
                .fixedSize()
                .buttonStyle(.bordered)
                .tint(Color.tpReferenceBlue)
                .disabled(isWorking)
                if let file {
                    ShareLink(item: file) {
                        Label(language.text("공유", "Share"), systemImage: "square.and.arrow.up")
                            .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(13)), weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(Color.tpReferenceBlue)
                }
            }
            Text(status.isEmpty
                 ? language.text("위치 점(위도·경도·고도·시각)만 담아요. 활동·건강·가계부·메모는 들어가지 않고, 다른 지도·운동 앱에서 열 수 있어요.",
                                 "Contains location points only (latitude, longitude, altitude, time). No activities, health, ledger or memos. Opens in other map and fitness apps.")
                 : status)
                .font(.taptionFixed(size: TaptionType.scaled(TaptionType.snapped(10.5)), weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func export(days: Int) {
        isWorking = true
        file = nil
        status = language.text("만드는 중…", "Preparing…")
        Task { @MainActor in
            defer { isWorking = false }
            do {
                let result = try await model.exportGPXURL(days: days)
                guard result.pointCount > 0 else {
                    status = language.text("이 기간에는 기기에 남은 위치 기록이 없어요.", "No location records on this device for that period.")
                    return
                }
                file = result.url
                status = language.text("위치 점 \(result.pointCount)개를 담았어요. 공유를 눌러 보내세요.", "\(result.pointCount) location points ready. Tap Share to send.")
            } catch {
                status = language.text("파일을 만들지 못했어요.", "Couldn't create the file.")
            }
        }
    }
}
