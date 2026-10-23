# 구조 진화 로드맵

이 문서는 "앞으로 어디로 갈 것인가"가 아니라 **"지금 무엇이 문제이고, 어떤 순서로,
무엇을 포기하면서 고칠 것인가"** 를 적는다. 모든 주장에는 측정값이 붙는다.
측정은 `scripts/architecture-metrics.py`가 하고, 기준선은
`docs/architecture-baseline.json`, 게이트는 CI의 `architecture` 잡이다.

기준선을 잰 시점: 2026-10-24, `0f6988b` + 이 문서의 Phase 0 변경.

---

## 0. 한 장 요약

| | 지금 | 목표 | 왜 |
|---|---:|---:|---|
| 가장 큰 파일 | 21,998줄 | ≤ 1,200줄 | 파일 하나를 열면 컨텍스트를 다 잃는다 |
| 가장 큰 타입 | 13,535줄 | ≤ 1,500줄 | 타입 하나가 8개 도메인의 상태를 들고 있다 |
| UI/UX → 엔진 직접 의존 | 0곳 (1 → 0) | 0곳 | **달성** — 뷰는 이제 엔진을 모른다. 경계 스크립트가 지킨다 |
| 도메인 모델 위치 | 앱 타깃 (`internal`) | `TaptionPlanCore` (`public`) | 지금은 패키지가 도메인을 못 봐서 어댑터가 번역만 한다 |
| 어댑터 줄 수 | 2,385줄 | ≤ 600줄 | 위 항목의 직접 비용 |
| Swift 6 탈출구 | 70곳 | 0곳 | `@unchecked Sendable` 25 · `nonisolated(unsafe)` 10 · `Task.detached` 29 · `fatalError` 1 · `DispatchQueue.main` 5 |
| 테스트 파일 최대 | 29,456줄 (756개) | ≤ 3,000줄 | 실패 하나가 어느 경계의 문제인지 안 보인다 |

이 문서가 **하지 않겠다고** 정한 것: 마이크로서비스, 모듈 100개, TCA 도입, 전체 재작성.
(§8 참고 — 이유를 적어 뒀다.)

---

## 1. 측정 방법

```bash
python3 scripts/architecture-metrics.py                    # 요약
python3 scripts/architecture-metrics.py --progress         # 목표까지 거리
python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json
```

`--check`는 다음 경우에 1로 끝난다.

1. 위험 표시가 기준선보다 **늘었을 때**
2. 가장 큰 파일/타입 줄 수가 **늘었을 때**
3. 예산(1,200줄)을 넘는 **새 파일이 생겼을 때**
4. 이미 넘은 파일이 **더 커졌을 때**
5. 총 줄 수가 기준선 대비 **10% 넘게 늘었을 때**

이 게이트의 성격을 분명히 해 둔다. **줄이지 않아도 실패하지 않는다. 늘리지만 않으면 된다.**
목표치(§0)는 `--progress`로 보여주기만 하고 판정에 쓰지 않는다.
목표를 게이트로 걸면 아직 멀다는 이유로 CI가 영원히 빨간불이 되고, 그러면 아무도 안 본다.

측정 대상은 **제품 소스만**이다(`TaptionPlan`, `TaptionPlanWidget`, `TaptionPlanWatch`,
`TaptionPlanWatchWidget`, `Packages`). `Tests` 디렉터리는 제외한다 — 테스트는 프로덕션
코드의 결함 지표가 아니고, 테스트를 늘리는 것이 벌점이 되면 안 된다.

---

## 2. 기준선

```
파일 126개 · 157,720줄
크기 분포: <500 71개 · 500-1000 20개 · 1000-2000 14개 · 2000-5000 17개 · 5000+ 4개
```

**좋은 소식부터.** 파일의 56%가 500줄 미만이고, 2,000줄을 넘는 파일은 21개(17%)다.
이 저장소는 "전부 스파게티"가 아니다. **소수의 거대 파일이 전체 인상을 지배하고 있다.**

```
  21,998  TaptionPlan/UI/MapHomeView.swift
  14,624  TaptionPlan/UX/AppModel.swift
  11,822  TaptionPlan/UI/ScheduleView.swift
   6,260  TaptionPlan/Core/SensorFusion.swift
   4,831  TaptionPlan/Core/AppleIntegrations.swift
   4,817  TaptionPlan/UI/ReviewView.swift
   4,661  TaptionPlan/Core/FeatureModels.swift
```

가장 큰 타입:

```
  13,535  class AppModel        (AppModel.swift)          ← 파일 14,624줄 중 13,535
  10,739  struct MapHomeView    (MapHomeView.swift)       ← 파일 21,998줄 중 10,739
   3,601  struct TimelineBoard  (ScheduleView.swift)
   3,340  struct ReviewView     (ReviewView.swift)
   2,127  actor TaptionPlanV3Store (DayStoreV3.swift)
```

테스트는 별도로 58,023줄이고, 그중 `FeatureEngineTests.swift` 하나가 29,456줄에
테스트 함수 756개를 담고 있다.

---

## 3. 진단

다섯 개만 적는다. 다섯 개 다 **측정 가능하고, 서로 다른 처방을 요구한다.**

### F1. 도메인 모델이 패키지 밖에 있다 — 의존성 방향이 뒤집혀 있다

`PlanRecord`, `ActualRecord`, `TravelSegment`, `TimeSpan`, `ActivityCorrection`,
`TaptionDataSnapshot` — 제품의 공용어 전부가 **앱 타깃**의
`TaptionPlan/Core/FeatureModels.swift`(4,661줄)에 있고, 전부 `internal`이다.

```
struct PlanRecord: Identifiable, Codable, Hashable, Sendable {   // FeatureModels.swift:774
struct ActualRecord: ...                                          // FeatureModels.swift:866
struct TimeSpan: ...                                              // FeatureModels.swift:749
```

패키지는 이 타입들을 **볼 수 없다.** 그래서 `Packages/TaptionActivityEngine`과
`Packages/TaptionRouteEngine`은 자기들만의 모델을 갖고, 앱이 둘 사이를 번역한다.
그 번역이 `TaptionActivityEngineAdapter.swift`(1,881줄) +
`TaptionRouteEngineAdapter.swift`(504줄) = **2,385줄**이다.

```
static func provenance(for actual: ActualRecord) -> ActivityDataProvenance   // 앱 타입 → 엔진 타입
static func trustLabel(for reading: SensorReading) -> String
```

**왜 비용인가.** 엔진에 기능을 하나 넣으면 앱에 어댑터를 하나 더 써야 하고,
어댑터는 테스트가 따로 필요하고, 모델이 바뀌면 두 곳이 같이 바뀐다.
2,385줄은 아무 기능도 만들지 않는다. **전부 경계를 넘는 통행료다.**

**처방.** 도메인 모델을 `TaptionPlanCore`로 올리고 `public`으로 만든다. → ADR-001

### F2. 엔진 경계가 이름뿐이다 — 배럴 파일이 경계 검사를 무력화한다

`Packages/TaptionPlanEngine/Sources/TaptionPlanEngine/TaptionPlanEngine.swift`는 **3줄**이다.

```swift
@_exported import TaptionPlanCore
@_exported import TaptionActivityEngine
@_exported import TaptionRouteEngine
```

`scripts/check-app-engine-import-boundary.sh`는 앱이 `import TaptionRouteEngine`을
쓰지 못하게 막는다. 그런데 `import TaptionPlanEngine` 한 줄이면 세 엔진 심볼이 전부
따라온다. **막는 것은 문자열 하나뿐이고, 실제 의존은 그대로 통과한다.**

이번에 실제로 그 구멍에 걸렸다. `TaptionPlan/UI/ScheduleView.swift`(당시 11,959줄,
타임라인 화면)가 배럴을 import하고 있었고, 그 이유는 딱 두 줄이었다.

```swift
RouteCoordinate(latitude: $0.latitude, longitude: $0.longitude)   // 2799
RoutePathSimplifier.simplify(routePoints, ...)                    // 2801
```

12,000줄짜리 뷰가 엔진 패키지 전체를 끌어온 이유가 **2개 표현식**이었다.
`RoutePolylineDecimator`(133줄)를 `Core/`로 옮기고 나니 뷰는 엔진을 전혀 몰라도 된다.

**Phase 0에서 한 일.** 경계 스크립트에 규칙을 하나 더 넣었다.

> **UI·UX 계층은 `TaptionPlanEngine`을 import하지 않는다. 엔진은 `Core/` 어댑터 뒤에만 있다.**

지금 이 규칙은 **실제로 지켜진다**(위반 0). 뷰가 엔진 타입을 직접 쓰면 화면 하나 고치려고
엔진을 다시 빌드해야 하고, 뷰 테스트에 엔진 픽스처가 딸려 온다.

**처방.** 남은 `Core/` 4개 파일의 배럴 의존을 정리하고, 배럴을 없앤다. → ADR-002

### F3. 세 개의 거대 타입이 변경 반경을 지배한다

**`struct MapHomeView` — 10,739줄, 그런데 파일은 21,998줄.**
파일을 세어 보면 최상위 선언이 **171개**이고, 그중 **63개가 `enum MapHome*`** 이다.
`MapHomeRouteFitMath`, `MapHomeWeatherTimelineMath`, `MapHomeDayPlaybackMath`,
`MapHomeStickmanAnnotationLayout`, `MapHomePawprintSpeedColor` …

이 63개는 대부분 **순수 함수**다. SwiftUI를 모르고, `self`를 안 쓰고, 입력만 받아 값을 낸다.
그런데 뷰 파일 안에 있어서 **뷰를 띄우지 않으면 테스트할 수 없다.**

이건 나쁜 소식이 아니라 **좋은 소식**이다. 22,000줄 중 11,000줄이 이미 이음매 없이
떼어낼 수 있는 상태로 놓여 있다. 자르는 데 설계가 필요 없다.

**`class AppModel` — 13,535줄, 이음매가 없다.**
`private(set) var` 관측 상태가 **64개**이고, 도메인이 최소 8개다: 센서 수집, HealthKit 동기화,
Apple Watch 연결, ScreenTime 사용 기록, 백업/복구, 보안/생체인증, 클라우드 동기화, 진단 내보내기.
파일 안에 `extension AppModel`이 **하나도 없다** — 누군가 이미 이음매를 만들려다 만 흔적조차 없다.

**`class FeatureEngineTests` — 26,068줄, 테스트 756개, `// MARK` 15개.**
첫 `MARK`가 5,006번째 줄이다. 그 앞 5,000줄은 무슨 기준으로 묶였는지 알 수 없다.

**처방.** MapHomeView는 정책 타입을 먼저 뽑고(설계 불필요), AppModel은 상태를 도메인별로
나눈 뒤(설계 필요) 자른다. → ADR-003

### F4. 저장소가 네 겹이고, V2와 V3가 함께 돈다

```
 2,408줄  Packages/TaptionPlanCore/.../DayStoreV3.swift     actor TaptionPlanV3Store
 1,493줄  TaptionPlan/Core/TaptionStoreV2.swift
 1,366줄  TaptionPlan/Core/PlanRepository.swift
   720줄  TaptionPlan/Core/PlanDayDatabase.swift
   419줄  Packages/TaptionPlanCore/.../StorageContracts.swift   ← 계약은 여기
```

`DEVELOPMENT.md`가 데이터 계약(TSR1 바이너리 레코드, `actual_records` 타입 행 + RTree,
`yyyy-MM-dd` 일별 백업, 복구 저널)을 아주 구체적으로 적어 두었다는 점이 중요하다.
**계약은 명확한데, 그 계약을 구현한 코드가 네 곳에 흩어져 있다.**

**왜 위험한가.** 쓰기 경로가 둘이면 백업/복구가 어느 쪽을 읽었는지에 따라 결과가 달라진다.
이건 성능 문제가 아니라 **데이터 정합성 문제**이고, 그래서 이 항목만 유일하게
"리팩터링"이 아니라 "버그 위험"으로 분류한다.

**처방.** V2를 지우는 게 아니라 **V2의 쓰기 경로를 닫는 것**이 목표다. → ADR-004

### F5. Swift 6 모드인데 탈출구가 70곳이다

프로젝트는 이미 `SWIFT_VERSION = 6.0`이다. **strict concurrency를 "켠다"는 제안은 틀렸다.**
이미 켜져 있고, 그 아래에서 사람이 손으로 연 구멍이 70개다.

```
unchecked_sendable    25   (@unchecked Sendable — 컴파일러에게 "믿어" 라고 말한 곳)
nonisolated_unsafe    10   (nonisolated(unsafe) — 격리를 손으로 껐다)
detached_tasks        29   (Task.detached — 구조화되지 않은 동시성)
fatal_error            1
main_queue             5
```

분포가 말해 주는 것이 있다. `MapHomeView.swift`의 `Task.detached` 8개는 **전부 같은 모양**이다.

```swift
return await Task.detached(priority: .userInitiated) {
    MapHomeCalendarLogStatusPolicy.statuses(actuals: actuals, travel: travel, ...)
}.value
```

**순수 함수를 메인 액터 밖에서 돌리려고** 뷰가 태스크를 직접 만들고 있다.
뷰가 오케스트레이션을 하고 있다는 증거이고, 동시에 이 8개는 기계적으로 정리 가능하다는
증거다(정책 타입이 `nonisolated`가 아니어서 생긴 일이다).

**처방.** F3의 정책 추출이 끝나면 이 8개는 대부분 사라진다. 나머지는 한 곳으로 모은다.

---

## 4. 목표 구조

바꾸는 것은 **의존 방향 하나**와 **경계 하나**다. 폴더를 예쁘게 만드는 게 목적이 아니다.

```
                    ┌──────────────────────────────┐
                    │  TaptionPlan (앱 셸)          │
                    │  UI/  UX/  Core/             │
                    │  · 뷰는 엔진을 모른다          │
                    │  · Core/ 어댑터만 엔진을 안다   │
                    └───────────────┬──────────────┘
                                    │ import TaptionPlanCore
                    ┌───────────────▼──────────────┐
                    │  TaptionPlanCore              │
                    │  도메인 모델 + 저장소 계약       │  ← F1의 목적지
                    │  (public, 순수 Swift)          │
                    └───────────────┬──────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
    TaptionActivityEngine   TaptionRouteEngine   (새 엔진은 여기에)
       활동 추론              경로 기하/추론
              └─────────────────────┴─────────────────────┘
                        세 엔진은 서로를 모른다
```

**의존 규칙 (전부 스크립트로 검사 가능)**

| 규칙 | 지금 | 검사 |
|---|---|---|
| `UI/`, `UX/` → 어떤 엔진도 import 금지 | **지킴** | `check-app-engine-import-boundary.sh` |
| 앱 → `TaptionRouteEngine`/`TaptionActivityEngine` 직접 import 금지 | 지킴 | 〃 |
| 엔진 패키지 → 앱/다른 엔진 import 금지 | 지킴 (Package.swift상 불가능) | 〃 |
| `TaptionPlanCore` → 엔진 import 금지 | 지킴 | 〃 |
| 거대 파일 예산 | 4개 초과 | `architecture-metrics.py --check` |
| Swift 6 탈출구 | 70곳 | 〃 |

`TaptionPlanEngine` 배럴은 **없앤다.** 배럴이 있으면 "이 파일이 무엇에 의존하는가"를
컴파일러도 사람도 알 수 없고, 경계 검사가 문자열 맞추기로 전락한다(F2).

---

## 5. 결정 기록

### ADR-001: 도메인 모델을 `TaptionPlanCore`로 올린다

**상태** 제안

**맥락**
F1. 공용어(`PlanRecord`, `ActualRecord`, `TimeSpan`, `ActivityCorrection`,
`TaptionDataSnapshot`)가 앱 타깃에 `internal`로 있고, 엔진 패키지는 그것을 볼 수 없다.
그 결과 2,385줄짜리 어댑터가 타입 번역만 한다.

**검토한 대안**

| 대안 | 얻는 것 | 잃는 것 | 판정 |
|---|---|---|---|
| A. 모델을 `TaptionPlanCore`로 올리고 `public` | 어댑터가 사라진다. 엔진이 도메인 타입으로 직접 말한다 | 모델을 바꿀 때 패키지 3개가 다시 빌드된다. `public`은 사실상 계약이라 함부로 못 바꾼다 | **채택** |
| B. 그대로 두고 어댑터를 더 잘 쓴다 | 지금 당장 아무것도 안 바뀐다 | 통행료가 계속 늘어난다. 이미 2,385줄 | 기각 |
| C. 모델을 별도 `TaptionDomain` 패키지로 분리 | 경계가 가장 선명하다 | 패키지가 5개가 되고, 순환 참조 위험이 생긴다. 지금 규모에 비해 과하다 | 보류 |
| D. 모델을 각 엔진에 복제 | 결합 없음 | 번역이 두 배, 불일치 위험 | 기각 |

**결정**
`Core/FeatureModels.swift`를 주제별로 쪼개 `TaptionPlanCore`로 옮기고 `public`으로 만든다.
한 번에 옮기지 않는다. **가장 많이 쓰이는 6개 타입부터** 옮기고, 어댑터가 줄어드는 것을
확인한 뒤 다음 묶음으로 간다.

**결과**
- 쉬워진다: 엔진에 기능 추가 = 어댑터 없이 가능. 어댑터 테스트가 줄어든다.
  도메인 규칙을 패키지 테스트(`swift test`)로 검증할 수 있다 — 지금은 앱 테스트(29,456줄)에서만 된다.
- 어려워진다: `public`이 된 타입은 변경이 곧 계약 변경이다. 그래서 **먼저 옮기고 나중에
  정리하는 순서를 택할 수 없다.** 옮기는 시점에 모양을 확정해야 한다.
- 되돌리기: 타입 단위로 옮기므로, 한 묶음이 문제면 그 묶음만 앱으로 되돌린다.

**하지 않을 것**: 이 ADR로 `Codable` 표현을 바꾸지 않는다. `DEVELOPMENT.md`의 저장 포맷은
이 작업 내내 **바이트 단위로 동일**해야 한다.

---

### ADR-002: `TaptionPlanEngine` 배럴을 없앤다

**상태** 제안

**맥락**
F2. 배럴 3줄이 경계 검사를 무력화한다. 실제로 `ScheduleView`가 엔진 전체를 끌어온 이유가
표현식 2개였고, 그 사실은 빌드가 깨질 때까지 아무도 몰랐다.

**검토한 대안**

| 대안 | 얻는 것 | 잃는 것 | 판정 |
|---|---|---|---|
| A. 배럴 삭제, 각자 필요한 패키지를 직접 import | 의존이 파일마다 명시된다. 경계 검사가 의미를 갖는다 | 앱 `Core/` 4개 파일이 import를 고쳐야 한다 | **채택** |
| B. 배럴 유지 + `@_exported`만 끊고 재수출 타입을 명시 | 한 곳에서 통제 | 명시 목록이 계속 늘고, 결국 두 번째 배럴이 된다 | 기각 |
| C. 배럴에 실제 오케스트레이션 코드를 넣는다 | 배럴이 정당해진다 | 지금 그 코드는 앱에 있고, 옮기는 것은 별개의 큰 결정 | 보류 |

**결정**
`Packages/TaptionPlanEngine`을 지운다. 앱에서 엔진이 필요한 4개 파일
(`TaptionActivityEngineAdapter`, `TaptionRouteEngineAdapter`, `RouteTimelineData`,
`RoutePolylineDecimator`)은 각자 `import TaptionActivityEngine` / `import TaptionRouteEngine`을 쓴다.
경계 스크립트는 이 4개 파일만 예외로 허용한다.

**결과**
- 쉬워진다: 파일을 열면 그 파일이 무엇에 의존하는지 첫 줄에서 안다. 뷰가 엔진을
  끌어오는 사고가 구조적으로 불가능해진다.
- 어려워진다: import 줄이 늘어난다. 사소하지만 실제 비용이다.
- 되돌리기: 배럴 파일 하나를 되살리면 된다. 가장 되돌리기 쉬운 결정.

---

### ADR-003: `AppModel`은 상속이 아니라 **조립**으로 나눈다

**상태** 제안

**맥락**
F3. 13,535줄, 관측 상태 64개, 도메인 8개, `extension` 0개.

**검토한 대안**

| 대안 | 얻는 것 | 잃는 것 | 판정 |
|---|---|---|---|
| A. 기능별 하위 모델을 `AppModel`이 소유 (`@Observable` 조립) | 뷰가 `model.sensor.…`로 읽어 관측 범위가 좁아진다. 파일이 도메인 경계에서 갈린다 | 하위 모델끼리 대화가 필요하면 `AppModel`이 중재해야 하고, 잘못하면 `AppModel`이 다시 커진다 | **채택** |
| B. 단일 리듀서(TCA/Elm 스타일) | 상태 전이가 한 곳에 모여 추론이 쉽다 | 756개 테스트와 171개 뷰를 전부 고쳐야 한다. `@Observable`과 궁합이 나쁘다. **전체 재작성에 가깝다** | 기각 |
| C. 파일만 `extension`으로 쪼갠다 (타입은 그대로) | 0-risk, 즉시 가능 | 13,535줄 타입은 그대로다. 변경 반경이 안 줄어든다 | **선행 단계로만 채택** |
| D. 액터로 감싼다 | 데이터 경합이 사라진다 | 64개 상태를 `await`로 읽어야 해서 모든 뷰가 비동기 렌더링이 된다 | 기각 |

**결정**
C → A 순서로 간다. 먼저 `extension AppModel`로 도메인별 파일을 만든다(동작 불변, 되돌리기 쉬움).
그다음 가장 독립적인 도메인부터 하위 모델로 떼어낸다. 순서는 **의존이 적은 것부터**:

1. `DiagnosticsExport` (27회 등장 — 가장 바깥)
2. `AppUsage` (ScreenTime, 24회)
3. `Backup` (80회)
4. `WatchConnectivity` (159회)
5. `HealthSync` (173회)
6. `SensorCollection` (342회)
7. 나머지(계획/스냅샷/실행취소)는 **마지막까지 남긴다** — 이게 진짜 핵심이고, 가장 얽혀 있다.

**결과**
- 쉬워진다: 센서 수집을 고칠 때 13,535줄을 열지 않는다. 뷰가 `model.sensor.isCollecting`만
  관측하므로 무관한 상태 변경에 다시 그려지지 않는다.
- 어려워진다: 하위 모델 간 순서가 있는 작업(센서 저장 → 스냅샷 갱신 → 위젯 반영)은
  `AppModel`이 명시적으로 순서를 정해야 한다. **이 순서가 암묵적이던 것이 지금의 진짜 문제**이고,
  나누는 과정에서 반드시 드러난다.
- 되돌리기: 하위 모델 하나를 다시 `AppModel`로 흡수하는 것은 기계적이다.

**하지 않을 것**: 실행취소/재실행(`AppModelHistoryEntry`)은 **건드리지 않는다.**
이건 이미 스냅샷 단위로 잘 정의돼 있고, 쪼개면 오히려 깨진다.

---

### ADR-004: V2는 지우지 않고 **쓰기 경로를 닫는다**

**상태** 제안

**맥락**
F4. 저장소가 네 겹이고 V2/V3가 함께 돈다. `DEVELOPMENT.md`의 데이터 계약은 명확한데
구현이 흩어져 있다.

**검토한 대안**

| 대안 | 얻는 것 | 잃는 것 | 판정 |
|---|---|---|---|
| A. V2를 읽기 전용으로 동결하고 새 쓰기는 전부 V3로 | 정합성이 한 곳으로 모인다. 되돌리기 쉽다 | 당분간 코드가 더 늘어난다(읽기 경로가 둘) | **채택** |
| B. V2 즉시 삭제 | 코드가 줄어든다 | 기존 기기의 데이터를 못 읽는다. 복구 저널이 깨진다 | 기각 |
| C. 그대로 둔다 | 0-risk | 쓰기 경로가 둘이라 백업/복구 결과가 경로에 따라 달라진다 | 기각 |

**결정**
V2의 쓰기 API에 `@available(*, deprecated)`를 붙이고, 새 호출이 생기면 CI에서 잡는다.
읽기 경로는 마이그레이션이 끝날 때까지 유지한다. **삭제는 이 로드맵의 범위 밖이다** —
삭제 시점은 실기기 데이터 마이그레이션 완료 후 별도 결정으로 남긴다.

**결과**
- 쉬워진다: "이 데이터는 누가 썼나"라는 질문의 답이 하나가 된다.
- 어려워진다: 당분간 저장소 코드가 가장 많은 상태로 유지된다. 파일 수는 안 줄어든다.
- 되돌리기: `deprecated` 표시를 떼면 된다.

---

## 6. 단계별 계획

각 단계는 **따로 배포 가능**해야 한다. 단계 하나가 실패하면 그 단계만 되돌린다.

### Phase 0 — 가드레일 (완료)

| 항목 | 상태 |
|---|---|
| `scripts/architecture-metrics.py` (요약·JSON·목표·기준선·게이트) | 완료 |
| `docs/architecture-baseline.json` | 완료 |
| CI `architecture` 잡 | 완료 |
| 경계 규칙 "UI·UX는 엔진을 모른다" + 실제 위반 0 | 완료 |
| `RoutePolylineDecimator`를 뷰에서 `Core/`로 이동 (뷰의 엔진 의존 제거) | 완료 |
| `ScheduleView`의 `import TaptionPlanEngine` 제거 | 완료 |

**증거**: `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json` 통과,
`bash scripts/check-app-engine-import-boundary.sh` 통과, 앱 빌드 성공.

이 단계가 먼저인 이유: 이후 모든 단계의 성과를 **숫자로 확인**해야 하고,
숫자 없이 "깔끔해졌다"고 말하면 6개월 뒤에 아무것도 안 남는다.

### Phase 1 — 이음매만 자르기 (동작 불변)

**범위**
1. `MapHomeView.swift`의 `enum MapHome*` 63개를 `TaptionPlan/Core/MapHome/` 아래 5개 파일로 이동:
   `+Geometry`(RouteFit, OverlayLayout, LocationMapMath), `+Timeline`(DayPlayback,
   WeatherTimeline, PlaybackZoom, TimeSidebarPinch), `+Route`(RouteReadings, GPSGap,
   ExpectedRoute, RouteOverlayCutoff), `+Growth`(Growth, Landmark, PawprintSpeed),
   `+Photo`(PhotoPolicy, PlacePinLayout, MemoPreview)
2. `FeatureEngineTests.swift`(29,456줄)를 도메인별 8개 파일로 분할. 첫 `MARK` 앞
   5,000줄을 먼저 분류하는 것이 이 작업의 실제 내용이다.
3. `AppModel.swift`를 `extension AppModel`로 도메인별 파일 분할 (타입은 그대로).

**왜 안전한가** 코드를 **한 글자도 안 바꾼다.** 이동만 한다. 같은 모듈이므로 접근 제어도
그대로다. 컴파일이 되면 끝이다.

**검증** 빌드 + 기존 테스트 전부 통과 + `--check` 통과(줄 수 불변).

**끝났다는 증거** `largest_file_lines` ≤ 12,000 (21,998 → 약 9,000),
`TaptionPlan/UI/MapHomeView.swift`가 뷰 선언만 담고 있음.

**이 단계가 옮기지 않는 것** `largest_type_lines`는 **13,535 그대로다.**
파일을 쪼개도 타입은 안 쪼개지기 때문이다. 그 지표는 Phase 4에서 움직인다.
이 구분을 흐리면 "파일 나눴으니 다 됐다"는 착각이 생긴다 — 그래서 지표를 두 개 둔다.

**예상 규모** 파일 이동 + pbxproj 등록. 새 파일 약 15개.

**주의** `MapHomeView.swift`의 정책 타입 중 일부는 `private`이다. `private`인 것은
같은 파일 안에서만 쓰인다는 뜻이므로, 옮길 때 `internal`로 넓히거나 그대로 둘 곳을 정해야 한다.
**이 판단이 이 단계의 유일한 설계 결정이다.**

### Phase 2 — 도메인 모델 승격 (ADR-001)

**범위** `FeatureModels.swift`(4,661줄)에서 가장 많이 쓰이는 6개 타입
(`TimeSpan`, `PlanRecord`, `ActualRecord`, `TravelSegment`, `ActivityCorrection`,
`TaptionDataSnapshot`)을 `TaptionPlanCore`로 옮기고 `public`으로 만든다.

**왜 안전한가** 타입을 옮겨도 `Codable` 합성 결과는 같다. 저장 포맷 불변.
`DEVELOPMENT.md`의 계약 테스트가 이걸 잡아 준다.

**검증** 기존 백업 파일을 읽고 다시 쓰는 왕복 테스트 + `swift test --package-path Packages/TaptionPlanCore`.

**끝났다는 증거** `TaptionActivityEngineAdapter`의 `provenance(for: ActualRecord)` 같은
번역 함수가 사라지거나 한 줄로 줄어듦. 어댑터 총 줄 수 2,385 → 2,000 이하.

**예상 규모** 이 단계가 **가장 위험하다.** 타입 6개가 49개 파일에서 쓰이고 있다
(`TimeSpan` 39 · `ActualRecord` 26 · `TravelSegment` 21 · `PlanRecord` 16 ·
`TaptionDataSnapshot` 11 · `ActivityCorrection` 4). 한 타입씩, 각각 별도 커밋으로 간다.

### Phase 3 — 배럴 제거 (ADR-002)

**범위** `Packages/TaptionPlanEngine` 삭제, 앱 `Core/` 4개 파일의 import 수정,
경계 스크립트에 4개 파일 예외 등록.

**왜 안전한가** import 문만 바뀐다. 심볼은 그대로 보인다.

**검증** 빌드 + 경계 스크립트.

**끝났다는 증거** `rg 'import TaptionPlanEngine'` 결과 0.

**예상 규모** 작다. Phase 2 뒤에 하는 이유는, Phase 2 전에는 앱 `Core/`가 배럴을 통해
`TaptionPlanCore`도 같이 받아 쓰고 있어서 import를 고치면 다른 곳이 깨지기 때문이다.

### Phase 4 — `AppModel` 분해 (ADR-003)

**범위** ADR-003의 순서대로 하위 모델 6개를 떼어낸다. 한 번에 하나, 각각 별도 배포.

**왜 안전한가** 하위 모델은 `AppModel`이 소유하고, 뷰는 `model.sensor.…`로 읽는다.
`AppModel`에 남는 것은 **중재 코드**뿐이고, 그 중재는 지금 암묵적으로 일어나는 일을
명시적으로 적은 것이다.

**검증** 각 하위 모델마다: 해당 도메인 테스트 + 전체 테스트 + 스크린샷 비교
(센서 수집 화면, 지도, 타임라인).

**끝났다는 증거** `largest_type_lines` ≤ 6,000 (13,535 → 목표 1,500까지는 여러 단계).

**예상 규모** 가장 크다. 6번의 배포.

**주의** 실행취소는 건드리지 않는다. 하위 모델이 늘어나면
`AppModelHistoryEntry`가 참조하는 상태가 흩어지므로, **실행취소 대상 상태는
`AppModel`에 남긴다**는 규칙을 먼저 정하고 시작한다.

### Phase 5 — 저장소 정합성 (ADR-004) + 탈출구 제거

**범위**
1. V2 쓰기 API 동결, V3 단일 쓰기 경로 확보
2. `Task.detached` 29 → 0: Phase 1에서 정책이 `Core/`로 나오면 `nonisolated`로 선언하고
   뷰의 태스크를 지운다. 남는 것은 한 곳의 헬퍼로 모은다
3. `@unchecked Sendable` 25 → 0: `AppleIntegrations.swift`(8개)가 최대集群.
   대부분 `CLLocationManagerDelegate`/`HKHealthStore` 콜백 브리지일 것이므로, `@MainActor` +
   `CheckedContinuation`으로 바꾼다
4. `nonisolated(unsafe)` 10 → 0, `DispatchQueue.main` 5 → 0

**왜 마지막인가** 이 항목들은 **다른 단계의 부산물**이다. Phase 1이 정책을 꺼내면
`Task.detached` 8개가 저절로 사라지고, Phase 4가 `AppModel`을 나누면 `@unchecked Sendable`이
붙은 이유 자체가 없어진다. 먼저 손으로 지우면 Phase 1~4에서 다시 생긴다.

**끝났다는 증거** `--progress`에서 위험 표시 6개가 전부 `달성`.

---

## 7. 가드레일

| 무엇 | 어디 | 언제 실패 |
|---|---|---|
| 엔진 경계 | `scripts/check-app-engine-import-boundary.sh` | UI/UX가 엔진 import, 앱이 구체 엔진 import |
| 구조 지표 | `scripts/architecture-metrics.py --check` | 위험 표시 증가, 거대 파일 증가, 새 거대 파일 |
| 데이터 계약 | `TaptionPlanTests/TaptionBackupV2Tests.swift`, `TaptionPlanCoreTests` | 저장 포맷 변경 |
| 패키지 테스트 | CI `packages` 잡 | 엔진/Core 회귀 |
| 앱 빌드 | CI `app` 잡 | 컴파일 실패 |

**기준선 갱신 절차.** 지표가 **좋아졌을 때만** 갱신한다.

```bash
python3 scripts/architecture-metrics.py --write-baseline docs/architecture-baseline.json
```

이 명령을 나쁜 방향으로 쓰면 게이트가 무의미해진다. 그래서 baseline 갱신은
**별도 커밋**으로 하고, 커밋 메시지에 어느 지표가 얼마나 좋아졌는지 적는다.
(예: `구조 지표: detached_tasks 29 → 21`)

---

## 8. 하지 않을 것

| 후보 | 왜 안 하는가 |
|---|---|
| 마이크로서비스 / 멀티레포 | 단일 iOS 앱이다. 네트워크 경계가 없는데 네트워크 비용을 만든다. 빌드 시간만 늘어난다 |
| 모듈을 20개로 쪼개기 | 이음매가 확인된 곳은 4곳이다. 나머지는 아직 경계를 모른다. **모르는 경계를 자르면 두 번 일한다** |
| TCA / 단일 리듀서 도입 | 756개 테스트와 171개 뷰를 다시 써야 한다. 얻는 것보다 잃는 것이 크다 (ADR-003) |
| 전체 재작성 | 157,717줄이고, 그중 상당 부분(수면 추론, 센서 융합, 백업 포맷)은 이미 잘 동작하고 테스트가 있다. 다시 쓰면 그 지식이 사라진다 |
| strict concurrency 켜기 | **이미 켜져 있다**(`SWIFT_VERSION = 6.0`). 문제는 켜져 있지 않은 게 아니라, 켜진 상태에서 사람이 연 구멍 70개다 |
| 폴더를 레이어별로 재정렬 | `UI/ UX/ Core/`는 이미 일관적이다. 폴더 이동은 diff만 만들고 의존을 안 바꾼다 |

---

## 9. 위험과 완화

| 위험 | 신호 | 완화 |
|---|---|---|
| Phase 2가 조용히 저장 포맷을 바꾼다 | 기존 백업을 못 읽음 | 타입 6개를 각각 별도 커밋. 매 커밋마다 왕복 테스트. `DEVELOPMENT.md` 계약을 테스트로 고정 |
| Phase 4가 실행취소를 깬다 | 실행취소 후 상태 불일치 | 실행취소 대상 상태를 `AppModel`에 남기는 규칙을 먼저 정한다. 실행취소 테스트를 손대지 않는다 |
| 지표 게이트가 형식적이 된다 | baseline이 나쁜 방향으로 갱신됨 | baseline 갱신은 별도 커밋 + 지표 변화 명시 |
| 거대 파일이 다시 자란다 | `--check` 실패 | 이미 게이트가 있다. 이게 Phase 0의 목적 |
| Phase 1에서 `private` 정책을 `internal`로 넓혀 캡슐화가 약해진다 | 새 `internal` 심볼이 앱 전체에서 보임 | 옮길 때 `private` → `internal`은 **같은 폴더 안에서만** 허용. 폴더 밖에서 쓰이면 그건 진짜 공용이다 |
| 작업이 기능 개발을 막는다 | 기능 PR이 리팩터링과 충돌 | 각 Phase를 파일 단위로 작게 유지한다. Phase 1은 순수 이동이라 충돌이 기계적으로 풀린다 |

---

## 부록: 지표 정의

| 지표 | 정의 | 왜 이 지표인가 |
|---|---|---|
| `largest_file_lines` | 제품 소스 파일 중 최대 줄 수 | 파일 크기는 "한 번에 읽어야 하는 양"이다. 리뷰 품질과 직접 연결된다 |
| `largest_type_lines` | 최상위 선언 중 최대 줄 수 (괄호 짝으로 계산) | 파일을 쪼개도 타입이 크면 응집도는 그대로다. 이 지표가 진짜다 |
| `unchecked_sendable` | `@unchecked Sendable` 개수 | 컴파일러 검사를 손으로 끈 곳. 늘어나면 동시성 안전이 줄어든 것 |
| `nonisolated_unsafe` | `nonisolated(unsafe)` 개수 | 격리를 손으로 끈 곳 |
| `detached_tasks` | `Task.detached` 개수 | 구조화되지 않은 동시성. 취소·우선순위 전파가 안 된다 |
| `fatal_error` / `try!` | 프로세스를 죽이는 코드 | 사용자 기기에서 앱이 죽는 경로 |
| `main_queue` | `DispatchQueue.main` 개수 | Swift Concurrency와 섞이면 순서 보장이 사라진다 |
| `singleton_reach` | `.shared` 개수 (**게이트 아님**) | `URLSession.shared` 같은 애플 API라 결함 지표가 아니다. 참고용 |

`type_sizes`는 중괄호 짝을 세어 최상위 선언의 끝을 찾는다. 문자열 리터럴 안의 중괄호를
구분하지 않으므로 ±수 줄 오차가 있을 수 있다. **추세를 보는 지표이지 정밀 계측이 아니다.**
