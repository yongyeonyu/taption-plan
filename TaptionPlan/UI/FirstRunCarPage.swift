import AVFoundation
import SwiftUI

/// 튜토리얼 「내 차」(CRT1111A01): 블루투스로 잡힌 오디오 기기 중 차를 고른다.
/// iOS는 페어링된 기기 목록을 앱에 주지 않아, 지금 연결된 기기와 이동 중에 앱이 본 기기를 보인다. CarPlay는 연결되면 저절로 등록된다.
struct FirstRunCarPage: View {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @State private var connected: [String] = []

    private var registered: [String] { model.settings.registeredCarAudioNames }
    /// 지금 연결된 기기, 이동 중에 본 기기, 이미 등록한 기기를 한 목록으로.
    private var candidates: [String] {
        AppFeatureSettings.normalizedCarAudioNames(connected + model.settings.recentCarAudioNames + registered)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if candidates.isEmpty {
                    Text(language.text(
                        "아직 잡힌 블루투스 기기가 없어요. 차에 타서 블루투스를 연결한 뒤 이 화면이나 메뉴 › 내 차 오디오에서 고를 수 있어요.",
                        "No Bluetooth devices yet. Connect your car's Bluetooth, then pick it here or in Menu › My car audio."
                    ))
                    .font(.taptionStyle(.subheadline))
                    .foregroundStyle(Color.tpSecondary)
                }
                ForEach(candidates, id: \.self) { name in
                    let isCar = registered.contains(name)
                    Button {
                        Task { await model.setCarAudio(name, isMyCar: !isCar) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isCar ? "car.fill" : "headphones")
                                .foregroundStyle(isCar ? Color.tpAccent : Color.tpSecondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.taptionStyle(.body, weight: .semibold)).foregroundStyle(Color.tpInk)
                                if connected.contains(name) {
                                    Text(language.text("지금 연결됨", "Connected now"))
                                        .font(.taptionStyle(.caption)).foregroundStyle(Color.tpSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: isCar ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isCar ? Color.tpAccent : Color.tpBorder)
                        }
                        .padding(12)
                        .background(Color.tpCard, in: RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: TaptionCorner.medium, style: .continuous).stroke(Color.tpBorder, lineWidth: TaptionBorder.width) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isCar ? .isSelected : [])
                }
                Text(language.text("CarPlay로 연결되는 차는 고르지 않아도 저절로 등록돼요.", "Cars that connect with CarPlay are registered automatically."))
                    .font(.taptionStyle(.caption))
                    .foregroundStyle(Color.tpSecondary)
                LedgerTollVehiclePicker(model: model, language: language)
                    .padding(.top, 8)
            }
            .padding(18)
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).receive(on: RunLoop.main)) { _ in refresh() }
    }

    private func refresh() {
        let ports: Set<AVAudioSession.Port> = [.carAudio, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.filter { ports.contains($0.portType) }.map(\.portName)
        if names != connected { connected = names }
    }
}

/// 내 차 종류(TOL1112B01). 고속도로 통행료 할인을 여기에 맞춰 계산한다. 튜토리얼 「내 차」와 메뉴 › 내 차 오디오에 같이 쓴다.
struct LedgerTollVehiclePicker: View {
    let model: AppModel
    let language: MapHomeLanguage
    @AppStorage(LedgerTollDiscount.vehicleKey) private var raw = LedgerTollDiscount.Vehicle.standard.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("내 차 종류", "My car type"))
                .font(.taptionStyle(.subheadline, weight: .semibold))
                .foregroundStyle(Color.tpInk)
            Picker(language.text("내 차 종류", "My car type"), selection: $raw) {
                ForEach(LedgerTollDiscount.Vehicle.allCases, id: \.rawValue) { vehicle in
                    Text(LedgerTollDiscount.name(vehicle, language: language)).tag(vehicle.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(language.text(
                "고속도로 통행료를 자동으로 넣을 때 할인을 계산해요. 경차는 50%, 전기·수소차는 올해 30%, 평일 출퇴근 시간에는 20~50%예요. 하이브리드는 일반이에요.",
                "Used for highway toll discounts when tolls are added automatically: compact cars 50%, EVs 30% this year, weekday commute hours 20–50%. Hybrids count as standard."
            ))
            .font(.taptionStyle(.caption))
            .foregroundStyle(Color.tpSecondary)
        }
        .onChange(of: raw) { _, _ in Task { await LedgerTollRepeatRunner.run(model: model, force: true) } }
    }
}
