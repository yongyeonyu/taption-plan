// swift-tools-version: 6.0
import PackageDescription

// AI 기능의 패키지(AIX1114A01). 규칙(`TaptionRules`), 명령 값·동작 등록부의 읽기 쪽(`TaptionAssistantProtocol`),
// 중계 전송·등록·PIN·연결 키·맡긴 일·질문 저장소(`TaptionAssistantKit`)가 있고, 명령·실행·동기화·화면은 `docs/AI_RELAY_PLAN.md`의 순서로 옮겨 온다.
let package = Package(
    name: "TaptionAssistant",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TaptionRules", targets: ["TaptionRules"]),
        .library(name: "TaptionAssistantProtocol", targets: ["TaptionAssistantProtocol"]),
        .library(name: "TaptionAssistantKit", targets: ["TaptionAssistantKit"])
    ],
    dependencies: [
        // 문구의 언어 값(`AppLanguagePreference.ResolvedLanguage`)만 쓴다.
        .package(path: "../TaptionWatchSync")
    ],
    targets: [
        // 화면·앱 모델·저장소를 모른다. Foundation만 쓴다.
        .target(name: "TaptionRules"),
        .testTarget(name: "TaptionRulesTests", dependencies: ["TaptionRules"]),
        // 명령에 실려 오는 값과 그것을 읽는 순수 함수, 동작 등록부의 읽기 쪽. Foundation과 언어 값만 쓴다.
        .target(name: "TaptionAssistantProtocol", dependencies: [.product(name: "TaptionWatchSync", package: "TaptionWatchSync")]),
        // 중계 서버 전송·키 보관·등록·맡긴 일. 앱 모델·화면을 모르고, 앱 설정·잠금은 `AssistantEnvironment`로 받는다.
        .target(name: "TaptionAssistantKit", dependencies: ["TaptionAssistantProtocol"]),
        .testTarget(name: "TaptionAssistantKitTests", dependencies: ["TaptionAssistantKit"])
    ]
)
