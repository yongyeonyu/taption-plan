import Foundation

/// 내 차 등록: CarPlay는 자동으로, 일반 블루투스는 앱을 열 때 물어서(CAR1111A01).
extension AppModel {
    /// CarPlay는 차에서만 연결되므로 묻지 않고 내 차로 등록한다. 차가 여러 대면 모두 쌓인다.
    func registerCarPlay(_ name: String) async {
        // 사용자가 내 차가 아니라고 했거나 등록을 뺀 기기는 다시 넣지 않는다.
        guard !settings.dismissedCarAudioNames.contains(name) else { return }
        let registered = AppFeatureSettings.normalizedCarAudioNames(settings.registeredCarAudioNames + [name])
        guard registered != settings.registeredCarAudioNames else { return }
        TaptionPlanDiagnosticsLogger.shared.record(
            "car_play_registered", fields: ["registered_count": String(registered.count)]
        )
        await updateCarAudioNames(registered: registered, recent: settings.recentCarAudioNames.filter { $0 != name })
    }

    /// 앱을 켰을 때 이미 CarPlay에 연결돼 있으면 등록한다.
    func registerConnectedCarPlay() async {
        guard let name = AppleSensorCollector.currentCarPlayName() else { return }
        await registerCarPlay(name)
    }

    /// 앱을 열 때 물어볼 기기. 타는 동안만 연결된 미등록 기기 중 아직 답하지 않은 가장 최근 것.
    var pendingCarAudioSuggestion: String? {
        settings.recentCarAudioNames.first {
            !settings.registeredCarAudioNames.contains($0) && !settings.dismissedCarAudioNames.contains($0)
        }
    }

    /// 「내 차로 등록할까요?」의 답이자 등록 창의 등록·빼기. 아니요·빼기는 다시 묻거나 자동 등록하지 않는다.
    func setCarAudio(_ name: String, isMyCar: Bool) async {
        let others = { (names: [String]) in names.filter { $0 != name } }
        snapshot.settings.dismissedCarAudioNames = isMyCar
            ? others(settings.dismissedCarAudioNames)
            : AppFeatureSettings.normalizedCarAudioNames(settings.dismissedCarAudioNames + [name])
        let registered = isMyCar
            ? AppFeatureSettings.normalizedCarAudioNames(settings.registeredCarAudioNames + [name])
            : others(settings.registeredCarAudioNames)
        await updateCarAudioNames(registered: registered, recent: others(settings.recentCarAudioNames))
    }

    /// 튜토리얼 「내 차」 줄의 켜고 끄기(FRT1117A01). 끄면 등록만 풀고 최근 목록 앞에 돌려 둔다.
    /// 「아니요」·「삭제」와 달리 거절로 남기지 않아, 줄이 남고 다시 눌러 되돌릴 수 있다.
    func toggleTutorialCarAudio(_ name: String) async {
        guard settings.registeredCarAudioNames.contains(name) else {
            await setCarAudio(name, isMyCar: true)
            return
        }
        await updateCarAudioNames(
            registered: settings.registeredCarAudioNames.filter { $0 != name },
            recent: AppFeatureSettings.normalizedCarAudioNames([name] + settings.recentCarAudioNames)
        )
    }
}
