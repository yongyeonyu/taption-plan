import Foundation
import TaptionPlanCore

/// 메뉴에 보여 줄 Watch 앱 설치 상태. `WCSession`과 Watch 앱이 알린 값만 쓴다.
enum AppleWatchAppStatus: Equatable, Sendable {
    case unavailable
    case notInstalled
    case installed(version: TaptionWatchAppVersion?, updateAvailable: Bool)

    static func make(
        state: AppleWatchConnectionState,
        version: TaptionWatchAppVersion?,
        iPhoneBuild: String
    ) -> Self {
        switch state {
        case .unsupported, .notPaired: .unavailable
        case .appNotInstalled: .notInstalled
        case .noRecentData, .background, .reachable:
            .installed(version: version, updateAvailable: version?.isOlder(thanBuild: iPhoneBuild) ?? false)
        }
    }
}

/// Watch 앱을 처음 확인했을 때 저전력 수집을 켠다. 그 뒤 사용자가 끄면 다시 켜지 않는다.
enum AppleWatchCollectionDefaults {
    static let appliedKey = "appleWatchCollectionDefaultsApplied"

    static func enabledProfiles(
        acceleration: TaptionWatchAccelerationProfile,
        dataSync: TaptionWatchDataSyncProfile,
        state: AppleWatchConnectionState,
        alreadyApplied: Bool
    ) -> (acceleration: TaptionWatchAccelerationProfile, dataSync: TaptionWatchDataSyncProfile)? {
        switch state {
        case .unsupported, .notPaired, .appNotInstalled: return nil
        case .noRecentData, .background, .reachable: break
        }
        guard !alreadyApplied else { return nil }
        return (
            acceleration == .off ? .balanced : acceleration,
            dataSync == .off ? .batterySaver : dataSync
        )
    }
}

/// 메뉴 연동 토글. 끄면 Watch 수집·전송을 멈추고 건강 앱 조회만 남는다.
enum AppleWatchLink {
    static let enabledKey = "appleWatchLinkEnabled"
    /// iPhone의 Watch 앱. 설치·업데이트는 앱이 직접 할 수 없어 여기로 보낸다.
    static let watchAppURL = URL(string: "itms-watchs://")

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }
}

/// 메뉴에 보여 줄 Watch 앱 상태. 건강 앱 조회 시각과 섞지 않는다.
enum AppleWatchMenuStatus: Equatable, Sendable {
    case unavailable
    case linkOff
    case installNeeded
    case waiting(lastData: Date?)
    case connected(lastData: Date?)

    static func make(
        state: AppleWatchConnectionState,
        linkEnabled: Bool,
        lastDataAt: Date?
    ) -> Self {
        switch state {
        case .unsupported, .notPaired: .unavailable
        case _ where !linkEnabled: .linkOff
        case .appNotInstalled: .installNeeded
        case .noRecentData: .waiting(lastData: lastDataAt)
        case .background, .reachable: .connected(lastData: lastDataAt)
        }
    }
}

/// 첫 실행에서 한 번만 보여 주는 Apple Watch 안내.
enum AppleWatchOnboardingPrompt: String, Sendable, CaseIterable {
    /// 워치는 있는데 워치 앱이 없다. 설치를 권한다.
    case installInvitation
    /// 페어링된 워치가 없다. 워치가 있어야 되는 것만 알린다.
    case watchlessLimitations
}

/// 연결 상태를 안내 한 줄로 옮기는 규칙. `WCSession` 값은 세션이 활성화된
/// 뒤에야 뜻이 생기고 나중에 바뀌기도 해서, 판단을 값 계산으로 떼어내
/// 화면과 저장은 이 결과만 본다. 시뮬레이터에는 페어링된 워치가 없으므로
/// 테스트도 여기만 본다.
enum AppleWatchOnboarding {
    static func prompt(
        for state: AppleWatchConnectionState,
        dismissed: Set<AppleWatchOnboardingPrompt>,
        hasSeenWatchAppInstalled: Bool
    ) -> AppleWatchOnboardingPrompt? {
        let candidate: AppleWatchOnboardingPrompt?
        switch state {
        // iPad이거나 아직 세션이 활성화되기 전이다. 워치가 없다고 단정할 수
        // 없으므로 아무것도 말하지 않는다.
        case .unsupported:
            candidate = nil
        case .notPaired:
            candidate = .watchlessLimitations
        // 한 번이라도 설치를 확인했다면 사용자가 직접 지운 것이다. 다시
        // 권하지 않는다.
        case .appNotInstalled:
            candidate = hasSeenWatchAppInstalled ? nil : .installInvitation
        case .noRecentData, .background, .reachable:
            candidate = nil
        }
        guard let candidate, !dismissed.contains(candidate) else { return nil }
        return candidate
    }

    /// 워치가 없을 때 실제로 줄어드는 것. 아이폰이 이미 하는 일을 없다고
    /// 적으면 거짓말이 되므로, 워치 신호에서만 나오는 것만 적는다.
    static var watchlessLimitations: [String] {
        watchlessLimitations(preference: .current)
    }

    static func watchlessLimitations(
        preference: AppLanguagePreference
    ) -> [String] {
        [
            AppLanguagePreference.text(
                korean: "계단·엘리베이터·양치·타이핑처럼 손목 움직임으로 나뉘는 세부 행동. iPhone만으로는 정지·걷기·달리기·자전거·자동차까지 구분합니다.",
                english: "Fine-grained actions told apart by wrist movement, such as stairs, elevators, brushing teeth and typing. The iPhone alone distinguishes still, walking, running, cycling and driving.",
                preference: preference
            ),
            AppLanguagePreference.text(
                korean: "‘집안일’ 구분. 집에 머문 시간을 집안일과 휴식으로 가르지 못합니다.",
                english: "Telling “housework” apart. Time at home cannot be split into housework and rest.",
                preference: preference
            ),
            AppLanguagePreference.text(
                korean: "심박수. 앱이 심박수를 읽을 수 있는 곳은 워치뿐입니다.",
                english: "Heart rate. The Watch is the only place the app can read heart rate.",
                preference: preference
            ),
            AppLanguagePreference.text(
                korean: "이동수단을 확정해 주는 워치 운동 기록. 대신 GPS·기압·걸음으로 추정합니다.",
                english: "Watch workout records that confirm the mode of transport. It is estimated from GPS, barometer and steps instead.",
                preference: preference
            ),
            AppLanguagePreference.text(
                korean: "손목에서 바로 시작하는 기록과 되묻기.",
                english: "Recording started right from your wrist, and follow-up questions.",
                preference: preference
            ),
        ]
    }

    /// 워치가 없어도 그대로인 것. 손해를 부풀리지 않기 위해 함께 보여 준다.
    static var iPhoneOnlyCoverage: String {
        iPhoneOnlyCoverage(preference: .current)
    }

    static func iPhoneOnlyCoverage(preference: AppLanguagePreference) -> String {
        AppLanguagePreference.text(
            korean: "걸음·거리·층수, 걷기·달리기·자전거·자동차 구분, 장소와 이동 경로, 날씨, 앱 사용시간, 사진, 캘린더, 회의·통화·근무 같은 머문 자리 구분은 iPhone만으로 그대로 기록됩니다.",
            english: "Steps, distance and floors, telling walking, running, cycling and driving apart, places and routes, weather, app usage time, photos, calendar, and stays such as meetings, calls and work are still recorded on the iPhone alone.",
            preference: preference
        )
    }

    /// Watch 앱을 여는 공개 URL 스킴은 없다. 눌러도 아무 일이 없을 수 있는
    /// 버튼 대신 찾아가는 길을 글로 적는다.
    static var installInstruction: String {
        installInstruction(preference: .current)
    }

    static func installInstruction(preference: AppLanguagePreference) -> String {
        AppLanguagePreference.text(
            korean: "iPhone의 Watch 앱 → 나의 시계 → 사용 가능한 앱 → BOKKI Plan에서 ‘설치’",
            english: "In the Watch app on iPhone → My Watch → Available Apps → tap “Install” next to BOKKI Plan",
            preference: preference
        )
    }

    /// 설정에 늘 있는 줄. 안내를 닫았거나 못 본 사람도 워치 앱이 있다는 것을
    /// 여기서 알 수 있어야 해서 사라지지 않고, 상태에 따라 문구만 바뀐다.
    static func companionRow(
        for state: AppleWatchConnectionState,
        preference: AppLanguagePreference = .current
    ) -> AppleWatchCompanionRow {
        switch state {
        // 아직 워치를 못 찾았거나 확인할 수 없는 기기다. 있다는 사실과 무엇이
        // 더해지는지만 알린다.
        case .unsupported, .notPaired:
            AppleWatchCompanionRow(
                subtitle: AppLanguagePreference.text(
                    korean: "손목 센서로 하루를 함께 적는 워치 앱이 있습니다",
                    english: "A Watch app records your day with wrist sensors",
                    preference: preference
                ),
                value: AppLanguagePreference.text(
                    korean: "안내",
                    english: "Info",
                    preference: preference
                ),
                detail: AppLanguagePreference.text(
                    korean: "Apple Watch를 연결하면 \(watchlessLimitations(preference: preference).count)가지가 더해집니다. \(iPhoneOnlyCoverage(preference: preference))",
                    english: "Connecting an Apple Watch adds \(watchlessLimitations(preference: preference).count) things. \(iPhoneOnlyCoverage(preference: preference))",
                    preference: preference
                )
            )
        case .appNotInstalled:
            AppleWatchCompanionRow(
                subtitle: AppLanguagePreference.text(
                    korean: "연결된 Apple Watch에 아직 설치되지 않았습니다",
                    english: "Not yet installed on your connected Apple Watch",
                    preference: preference
                ),
                value: AppLanguagePreference.text(
                    korean: "설치 필요",
                    english: "Install needed",
                    preference: preference
                ),
                detail: installInstruction(preference: preference)
            )
        case .noRecentData:
            AppleWatchCompanionRow(
                subtitle: AppLanguagePreference.text(
                    korean: "워치 앱은 설치됐지만 최근 데이터가 없습니다",
                    english: "The Watch app is installed but has no recent data",
                    preference: preference
                ),
                value: AppLanguagePreference.text(
                    korean: "수신 대기",
                    english: "Waiting for data",
                    preference: preference
                ),
                detail: AppLanguagePreference.text(
                    korean: "최근 15분 내 센서·건강 데이터 수신 시 연결됨으로 표시합니다.",
                    english: "Shown as connected when sensor or Health data arrives within the last 15 minutes.",
                    preference: preference
                )
            )
        case .background, .reachable:
            AppleWatchCompanionRow(
                subtitle: AppLanguagePreference.text(
                    korean: "Apple Watch에 설치되어 손목 센서를 함께 기록합니다",
                    english: "Installed on your Apple Watch and recording with wrist sensors",
                    preference: preference
                ),
                value: AppLanguagePreference.text(
                    korean: "설치됨",
                    english: "Installed",
                    preference: preference
                ),
                detail: nil
            )
        }
    }
}
