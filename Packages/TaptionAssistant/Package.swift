// swift-tools-version: 6.0
import PackageDescription

// AI 기능의 패키지(AIX1114A01). 지금은 규칙 모델·평가기(`TaptionRules`)만 있고,
// 명령·일·동기화·화면은 `docs/AI_RELAY_PLAN.md`의 순서로 옮겨 온다.
let package = Package(
    name: "TaptionAssistant",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TaptionRules", targets: ["TaptionRules"]),
        .library(name: "TaptionAssistantProtocol", targets: ["TaptionAssistantProtocol"])
    ],
    targets: [
        // 화면·앱 모델·저장소를 모른다. Foundation만 쓴다.
        .target(name: "TaptionRules"),
        .testTarget(name: "TaptionRulesTests", dependencies: ["TaptionRules"]),
        // 명령에 실려 오는 값과 그것을 읽는 순수 함수. Foundation만 쓴다.
        .target(name: "TaptionAssistantProtocol")
    ]
)
