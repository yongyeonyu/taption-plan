// swift-tools-version: 6.0
import PackageDescription

// AI 기능의 패키지(AIX1114A01). 규칙(`TaptionRules`), 명령 값·동작 등록부(읽기 형·목록·종류)(`TaptionAssistantProtocol`),
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
        .package(path: "../TaptionWatchSync"),
        // 가계부 값 타입(`LedgerEntry`·`LedgerCategory`)만 쓴다(RMN1114A25).
        .package(path: "../TaptionLedgerCore"),
        // 저장 본문의 값 타입(장소 종류·내 정류장 종류·층 범위)만 쓴다. 저장소(`TaptionStoreRepository`)는 부르지 않는다(RMN1114A25).
        .package(path: "../TaptionPlanStore"),
        // 이동 수단 값(`TravelMode`)만 쓴다.
        .package(path: "../TaptionPlanCore")
    ],
    targets: [
        // 화면·앱 모델·저장소를 모른다. Foundation만 쓴다.
        .target(name: "TaptionRules"),
        .testTarget(name: "TaptionRulesTests", dependencies: ["TaptionRules"]),
        // 명령에 실려 오는 값과 그것을 읽는 순수 함수, 동작 등록부(읽기 형·목록·종류). Foundation과 언어 값·가계부 값·규칙 값·저장 본문 값만 쓴다.
        .target(name: "TaptionAssistantProtocol", dependencies: [
            "TaptionRules",
            .product(name: "TaptionWatchSync", package: "TaptionWatchSync"),
            .product(name: "TaptionLedgerCore", package: "TaptionLedgerCore"),
            .product(name: "TaptionPlanStore", package: "TaptionPlanStore"),
            .product(name: "TaptionPlanCore", package: "TaptionPlanCore")
        ]),
        .testTarget(name: "TaptionAssistantProtocolTests", dependencies: ["TaptionAssistantProtocol"]),
        // 중계 서버 전송·키 보관·등록·맡긴 일. 앱 모델·화면을 모르고, 앱 설정·잠금은 `AssistantEnvironment`로 받는다.
        .target(name: "TaptionAssistantKit", dependencies: ["TaptionAssistantProtocol"]),
        .testTarget(name: "TaptionAssistantKitTests", dependencies: ["TaptionAssistantKit"])
    ]
)
