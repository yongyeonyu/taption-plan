import AVFoundation
import Combine
import SwiftUI

/// 내 차 오디오 기기 등록 창(CAR1029A01).
///
/// 등록한 기기(CarPlay·블루투스)가 연결된 이동은 자동차로 확정한다. 연결·해제가
/// 이동과 맞아떨어진 미등록 기기는 최근 목록에 올라 한 번에 등록할 수 있다.
struct MapHomeCarAudioSheet: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @Environment(\.dismiss) private var dismiss
    @State private var liveOutputs: [LiveOutput] = []

    struct LiveOutput: Identifiable, Equatable {
        var id: String { uid }
        var uid: String
        var name: String
        var portType: String
        var isCarAudio: Bool
    }

    private var registered: [String] { model.settings.registeredCarAudioNames }

    private var recent: [String] {
        model.settings.recentCarAudioNames.filter { !registered.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    registeredSection
                    recentSection
                    liveSection
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 14)
            }
        }
        .background(Color.tpBackground)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear(perform: refreshLiveOutputs)
        .onReceive(
            NotificationCenter.default
                .publisher(for: AVAudioSession.routeChangeNotification)
                .receive(on: DispatchQueue.main)
        ) { _ in
            refreshLiveOutputs()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("내 차 오디오", "My car audio"))
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(19)), weight: .bold, design: .rounded))
                Text(language.text(
                    "등록한 기기가 연결된 이동은 자동차로 확정합니다",
                    "Trips with a registered device connected are confirmed as car"
                ))
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
                .foregroundStyle(Color.tpSecondary)
                .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .bold))
                    .foregroundStyle(Color.tpSecondary)
                    .frame(width: TaptionMenuMetrics.minimumHitSize, height: TaptionMenuMetrics.minimumHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(language.text("닫기", "Close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private var registeredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(language.text("등록한 기기", "Registered devices"))
            if registered.isEmpty {
                emptyLine(language.text("아직 등록한 기기가 없습니다", "No device registered yet"))
            }
            ForEach(registered, id: \.self) { name in
                row(name: name, detail: nil) {
                    actionButton(language.text("삭제", "Remove"), filled: false) {
                        unregister(name)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(language.text("최근 연결된 기기", "Recently connected"))
            Text(language.text(
                "이동 시작·끝과 연결·해제가 맞았던 기기입니다",
                "Devices whose connect and disconnect matched a trip"
            ))
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .medium, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
            if recent.isEmpty {
                emptyLine(language.text("아직 없습니다", "None yet"))
            }
            ForEach(recent, id: \.self) { name in
                row(name: name, detail: nil) {
                    actionButton(language.text("내 차로 등록", "Register"), filled: true) {
                        register(name)
                    }
                }
            }
        }
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(language.text("지금 연결된 출력", "Current outputs"))
            if liveOutputs.isEmpty {
                emptyLine(language.text("연결된 출력이 없습니다", "No output connected"))
            }
            ForEach(liveOutputs) { output in
                row(name: output.name, detail: output.portType) {
                    if output.isCarAudio, !registered.contains(output.name) {
                        actionButton(language.text("내 차로 등록", "Register"), filled: true) {
                            register(output.name)
                        }
                    }
                }
            }
        }
    }

    private func row<Trailing: View>(
        name: String,
        detail: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: TaptionType.scaled(TaptionType.snapped(14)), weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: TaptionType.scaled(TaptionType.snapped(10)), weight: .medium, design: .rounded))
                        .foregroundStyle(Color.tpSecondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: TaptionMenuMetrics.minimumHitSize)
        .background(Color.tpSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func actionButton(_ title: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .bold, design: .rounded))
                .foregroundStyle(filled ? .white : Color.tpAccent)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(filled ? Color.tpAccent : Color.tpAccent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(12)), weight: .medium, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: TaptionType.scaled(TaptionType.snapped(11)), weight: .bold, design: .rounded))
            .foregroundStyle(Color.tpSecondary)
    }

    private func register(_ name: String) {
        let nextRegistered = AppFeatureSettings.normalizedCarAudioNames(registered + [name])
        let nextRecent = model.settings.recentCarAudioNames.filter { $0 != name }
        Task { await model.updateCarAudioNames(registered: nextRegistered, recent: nextRecent) }
    }

    private func unregister(_ name: String) {
        let nextRegistered = registered.filter { $0 != name }
        let recent = model.settings.recentCarAudioNames
        Task { await model.updateCarAudioNames(registered: nextRegistered, recent: recent) }
    }

    private func refreshLiveOutputs() {
        let carPorts: Set<AVAudioSession.Port> = [.carAudio, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map {
            LiveOutput(
                uid: $0.uid,
                name: $0.portName,
                portType: $0.portType.rawValue,
                isCarAudio: carPorts.contains($0.portType)
            )
        }
        if outputs != liveOutputs { liveOutputs = outputs }
    }
}
