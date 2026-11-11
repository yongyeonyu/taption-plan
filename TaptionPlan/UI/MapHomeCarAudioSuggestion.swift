import SwiftUI

/// 앱을 열 때 「이 기기가 내 차 같아요. 등록할까요?」를 묻는다(CAR1111A01).
/// 타는 동안만 연결·해제된 미등록 블루투스 기기가 후보다. CarPlay는 묻지 않고 등록한다.
struct MapHomeCarAudioSuggestion: ViewModifier {
    @Bindable var model: AppModel
    let language: MapHomeLanguage

    @Environment(\.scenePhase) private var scenePhase
    @State private var asking: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase, initial: true) { _, phase in
                guard phase == .active else { return }
                Task {
                    await model.registerConnectedCarPlay()
                    if asking == nil { asking = model.pendingCarAudioSuggestion }
                }
            }
            .alert(
                language.text("이 기기가 내 차 같아요", "This looks like your car"),
                isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
                presenting: asking
            ) { name in
                Button(language.text("내 차로 등록", "Register as my car")) {
                    Task { await model.setCarAudio(name, isMyCar: true) }
                }
                Button(language.text("아니요", "No"), role: .cancel) {
                    Task { await model.setCarAudio(name, isMyCar: false) }
                }
            } message: { name in
                Text(language.text(
                    "‘\(name)’ 기기가 탈 때만 연결됐어요. 등록할까요? 등록하면 이 기기가 연결된 이동을 자동차로 기록해요.",
                    "‘\(name)’ connected only while you rode. Register it? Trips with it connected will be recorded as car."
                ))
            }
    }
}

extension View {
    func mapHomeCarAudioSuggestion(model: AppModel, language: MapHomeLanguage) -> some View {
        modifier(MapHomeCarAudioSuggestion(model: model, language: language))
    }
}
