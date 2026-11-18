# Apple Foundation Models 3단계 길 (PCC1118A01)

대표 지시(2026-11-18): 메모 다듬기·지출·일정 초안·하루 요약을 유료 외부 API 없이 Apple 모델 먼저 처리한다.

## 길

| 순서 | 길 | 조건 | 안내(Alert 없이 한 줄) |
|---|---|---|---|
| 1 | Private Cloud Compute(`PrivateCloudComputeLanguageModel`, iOS 27+) | `availability == .available`, 한도 아래, 온라인, 기기 밖으로 보내도 됨, 입력 12,000자 이하 | 한도 임박 → `cloudQuotaApproaching` |
| 2 | 기기 안 모델(`SystemLanguageModel.default`, iOS 26+, 문맥 4K) | 1이 안 될 때, 기기 모델 가용, 작업별 글자 한도 이하(메모 다듬기 1,500·초안 1,200·하루 요약 0=쓰지 않음) | PCC 한도 도달 → `cloudQuotaReached` |
| 3 | 연결된 AI 중계 큐(`AITaskQueue`·`MemoPolishQueue`) | 그 밖(미지원 기기·지역·iOS 26 미만, 기기 한도 초과) | 기기 한도 초과 → `inputTooLongForDevice` |

- 판단: `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AppleModelRouter.swift`(순수 함수, FoundationModels를 모름). 시험: `AppleModelRouterTests`.
- 조건 읽기·PCC 호출: `TaptionPlan/UI/AppleModelEnvironment.swift`. PCC가 부를 때 실패하면(`quotaLimitReached`·`networkFailure`·`serviceUnavailable`·그 밖 모르는 오류) `AppleModelRouter.decide(after:_:)`로 다시 골라 기기 모델로 간다. 가드레일·언어·문맥 초과는 다른 길로 넘기지 않고 안내만 한다.
- 기기 밖으로 보내지 않는 경우: 글에 위도·경도 쌍이 있음(`AppleModelRouter.containsCoordinates`). 좌표를 AI로 보내지 않는 원칙(AGENTS.md)은 PCC에도 같다. AI 공유 수준 「끔」이어도 PCC는 쓴다(대표 결정 2026-11-18). 중계 큐(3순위)의 공유 수준 처리는 그대로다.
- 하루 요약은 기기 모델에서 하지 않는다(대표 결정 2026-11-18, 그대로).
- 연결된 곳(1차): 메모 편집 화면의 「AI 다듬기」. 3순위가 나오면 기존 「연결된 AI에게 맡기기」 상태를 켜고 저장할 때 `MemoPolishQueue`로 넘긴다. 지출·일정 초안과 하루 요약은 라우터의 작업 종류만 있고 아직 연결하지 않았다.
- iOS 18 기기: `#if canImport(FoundationModels)`·`#if compiler(>=6.4)`(CI Xcode 26에 없는 iOS 27 형식)·`@available(iOS 26/27, *)`로 가르고 프레임워크는 약한 연결이다. 둘 다 `.unsupported`가 되어 3순위로 간다.

## Entitlement (아직 승인 전)

- **스위치(대표 결정 2026-11-18 「승인 전엔 PCC 끔」)**: `AppleModelEnvironment.isPrivateCloudComputeEnabled = false`. 꺼져 있으면 PCC를 묻지도 부르지도 않고 라우터에 「쓸 수 없음」으로 넣어 기기 모델 → 중계 큐로 간다. PCC 호출 코드는 남아 있고, 실제 탐침 시험(`TAPTION_PCC_PROBE=1`)은 스위치와 상관없이 요청할 때만 돈다.
- 지금은 `.entitlements`·프로비저닝·서명 설정에 아무것도 넣지 않았다. 넣으면 승인 전 프로필과 맞지 않아 TestFlight 서명이 깨진다.
- entitlement가 없으면 iOS가 `availability`를 `.unavailable`로 알리거나 부를 때 거절한다. 어느 쪽이든 2·3순위로 간다(`testMissingEntitlementFallsBackToDevice`, 앱 시험 `testLiveConditionsReadWithoutCrash`). 시뮬레이터(iOS 27.0)에서는 `availability`가 `.available`로 읽히고 실제 호출이 거절되어 `service`로 분류된 뒤 기기 모델로 넘어갔다(`test.md` PCC1118A01). 그래서 승인 전에는 스위치로 꺼 둔다.
- SDK(iPhoneOS 27.2)의 `FoundationModels.swiftinterface`·`.tbd`에는 entitlement 키 이름이 없다. 키는 추측해 넣지 않고 포털 승인 화면에 나온 이름을 쓴다.

승인 뒤 할 일:
0. 아래 2·4번과 같은 커밋에서 `AppleModelEnvironment.isPrivateCloudComputeEnabled`를 `true`로 켠다.
1. Apple Developer 포털에서 App ID(앱 번들)에 승인된 PCC 기능을 켜고, 개발·배포 프로비저닝 프로필을 다시 만든다(자동 서명이면 Xcode에서 갱신).
2. 승인 화면의 entitlement 키를 `TaptionPlan/TaptionPlan.entitlements`와 `TaptionPlan/TaptionPlanDebug.entitlements`에만 넣는다(위젯·Watch에는 넣지 않는다).
3. 아이폰 11은 PCC 대상이 아니므로(Apple Intelligence 미지원) 지원 기기에서 `availability`·`quotaUsage`·실제 다듬기를 확인하고 `test.md`에 적는다.
4. 스위치를 켜는 커밋에 `PRIVACY.md` 한 줄을 함께 넣는다(대표 결정 2026-11-18 「PRIVACY.md는 PCC 켤 때 함께」). 초안: 「메모 다듬기 등 일부 글 정리는 Apple Intelligence의 Private Cloud Compute(Apple 서버)에서 처리될 수 있습니다. 이때 보내는 것은 그 글뿐이며 위치 좌표는 보내지 않습니다. Apple은 처리 뒤 이 글을 보관하지 않는다고 밝히고 있습니다.」
5. `scripts/testflight/release.sh --preflight`로 서명을 먼저 본다.
