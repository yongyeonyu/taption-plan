---
id: 20261120-1753-launch-event-bubble-reveal
created_at: 2026-11-20T17:53+09:00
status: pending
title: 일정(event) 말풍선은 앱을 켤 때 한 번만 먼저 보이고, 시간대 말풍선으로 넘긴다
from: 비야
request_id: BUB1120A01
basis: 대표 직접 지시 (2026-11-20 17:45 통화) — 「일정이 있으면 그 앱을 킬 때마다 일정을 먼저 보여주고, 그다음으로 그 시간대별로 맞는 말풍선으로 넘어가게, 그런 식으로 알고리즘 바꾸는 거 브릿지에 넘겨.」
---

대표 지시 한 줄(통화, 2026-11-20 17:45): **일정(event) 말풍선이 있으면 앱을 켤 때마다 그 일정을 먼저 보여 주고, 잠시 뒤 그 시각에 맞는 시간대 말풍선(routine)으로 넘어가게 알고리즘을 바꿔라.**

이 지시서는 **바꿀 동작을 못 박고, 무엇을 건드리지 않을지도 같이 못 박습니다.** 2절이 계약의 전부이고, 3절은 권장 구현입니다. 세부 구현은 구현자 판단이되 2절·6절·7절은 그대로 지켜야 합니다.

**처리 순서(브리지 공통, 2026-11-20 점검)**: 파일 이름 순서로 `1747 LAG1120A01`(시작 지연) **다음 두 번째**입니다. 시작 훅이 LAG가 재는 콜드 실행 구간에 들어가므로 **LAG의 전후 측정이 끝난 뒤**에 붙입니다. 폴링을 만지는 `1805 RTA1120A01`과는 다른 객체(`AssistantBubbleBoard`)를 만지므로 서로 덮지 않지만, 둘 다 홈 진입 `.task` 주변을 건드리니 **한 커밋에 섞지 않습니다**.

## 이 요청의 범위 (먼저 읽기)

1. **바꾸는 것 하나**: 앱을 켠 직후의 말풍선 **선택 순서**. 지금은 event가 그날 하루 종일 1순위라, 아침에 어제 요약을 event로 넣으면 하루 종일 그 문구만 떠서 시간대별 routine 말풍선이 전부 가려집니다(대표가 직접 겪고 지적). event를 「하루 종일 붙잡는 것」에서 **「켤 때 한 번 먼저 보여 주고 시간대 말풍선으로 넘기는 것」** 으로 바꿉니다.
2. **바꾸지 않는 것**: 말풍선 글 규칙(80자·링크·줄 수), 하루 48개 한도, 지난 event 정리(`isExpired`/`cleanExpired`), 재생·사이드바 핸들로 과거 시각을 보는 표시(`viewedTime`), 백업 미러(`AssistantBubbleArchive`), 노래방 가사 말풍선(`SeasonPackKaraokeBubble`), 3순위 기본 문구 풀(`MapHomeDefaultBubblePool`), 서버·중계(`server/trip-relay`, `validate.js`). 위 목록 중 하나라도 깨져야 이 변경이 성립한다면, 깨지 않는 다른 방법을 찾으십시오.
3. **서버 작업 없음**: 말풍선은 이미 받아 둔 기기 파일을 읽는 표시 문제입니다. 새 API·새 필드·배포 없음.

## 0. 시작할 때

1. `git pull --rebase`, `git status --short --branch`, `git log --oneline -5`.
2. **동시 작업 주의**: 같은 `inbox/`에 `20261120-1747-launch-lag-season-pack.md`(`LAG1120A01`)가 함께 있을 수 있습니다. 파일 이름 순서대로 처리하므로 이 문서는 그 뒤입니다. 남의 지시서·남의 파일을 건드리지 말고, 푸시 전에 `git pull --rebase origin main`을 한 번 더 합니다.
3. 다른 세션의 미커밋 변경이 있을 수 있습니다 — 특히 `TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`. 건드리지도, 이번 커밋에 넣지도 않습니다(`AGENTS.md` 7절). 경로를 지정해 이번에 만진 파일만 커밋합니다.
4. 동작 코드를 만지므로 빌드 잠금(`AGENTS.md` 5절, `/tmp/taptionplan-xcodebuild.lock`)과 병합·세션 규칙(`AGENTS.md` 7절)을 그대로 따릅니다.
5. **요청 ID `BUB1120A01`** 을 `AGENTS.md` 2절대로 씁니다: `test.md` `## 남은 작업` 「홈·UI」에 한 줄, `### 요청 상세`에 원인·해결·검증 기준·대표 결정. 착수 전에 `rg -n "BUB1120A01" test.md pickle-bridge`로 같은 ID가 없는지 확인하십시오(2026-11-20 17:51 확인 시 없음).
6. **저장소는 공개입니다.** 개인정보·계정·서버 주소·실제 좌표·실제 동네/가게 이름·키를 지시서·회신·커밋에 쓰지 않습니다(`AGENTS.md` 8절). 이 문서의 시각·문구는 모두 예시입니다.
7. **`Docs/pipeline/CHANGELOG.md`는 이 저장소에 없습니다.** 착수 시점(`ed824ea8`)에 `git ls-tree -r --name-only HEAD | grep -i changelog`로 확인했더니 아무것도 나오지 않고, `docs/`에는 `DATA_PIPELINE.md`만 있습니다. 그래서 이번 기록은 **`test.md` 2절(남은 작업 → 검증 기록)로 대신합니다**(5절). 없는 파일을 새로 만들어 기록을 나누지 마십시오.

## 1. 지금 저장소에서 확인한 사실 (2026-11-20 17:51, `origin/main` `ed824ea8` 기준 — 착수 때 `rg -n`으로 다시 확인하고 쓰십시오)

| 경로 | 지금 있는 것 | 이번에 보는 이유 |
|---|---|---|
| `TaptionPlan/UI/AssistantBubble.swift:118~120` | 구조체 주석 「event는 그날 하루 맨 앞에 보이고, 날이 지나면 기기에서 지운다」 | 지금 동작이 문서로도 박혀 있음 — 이 주석도 새 규칙으로 고칩니다 |
| `AssistantBubble.swift:207~213` | `AssistantBubbleStore.active(at:in:)` — 지금 시각에 유효한 것 중 `kind == .event`를 먼저, 없으면 `.routine`, 겹치면 **늦게 시작한 것**(`max { $0.start < $1.start }`). 끝은 배타(`start <= now < end`), `hidden`·`parsed == nil` 제외 | 1순위 규칙의 정본. **이 함수의 기본 동작은 그대로 둡니다**(기존 시험 `AssistantPhase3Tests.swift:656`이 「the day's event comes first」를 확인) |
| `AssistantBubble.swift:161` / `:178` / `:184` | `dayLimit = 48`, `isExpired`(event만, 그날 끝이 지나면), `cleanExpired` | 손대지 않음(지난 event 정리 규칙 유지) |
| `AssistantBubble.swift:169~175` | `save`가 `AssistantBubbleArchive.mirror`로 앱 DB에 미러 | 손대지 않음 |
| `AssistantBubble.swift:218~220` | `@Observable final class AssistantBubbleBoard`, `static let current`, `private(set) var active`, `@ObservationIgnored private var file`·`bubbles` | 세션 상태(켤 때 한 번 보여 줬는지)를 둘 자리 |
| `AssistantBubble.swift:229~243` | `refresh(now:)` — 파일은 한 번만 읽고, `viewedTime ?? now`로 `active(at:in:)`을 불러 값이 바뀔 때만 `active` 갱신. 파일이 비면 앱 DB에서 한 번 되살림 | 새 선택 규칙이 들어갈 자리 |
| `AssistantBubble.swift:245~251` | `show(at:)` — 재생·사이드바 핸들이 `viewedTime`을 바꾸고 `refresh()` | 켤 때 연출은 `viewedTime == nil`일 때만, 과거 시각을 보는 중이면 취소 |
| `AssistantBubble.swift:253~257` | `replace(_:file:now:)` — 저장할 때 목록을 받아 다시 고름 | 저장이 오면 연출 상태도 다시 판정(숨김이면 즉시 종료) |
| `AssistantBubble.swift:301~345` | `AssistantBubbleLinkBar` — `board.active`의 글·링크·`xmark`(누르면 `AssistantBubbleStore.hide`, 영구 숨김) | 「닫기」의 한 갈래. 숨김은 지금대로 영구여야 함 |
| `TaptionPlan/UI/MapHomeMapAnnotations.swift:403`·`:419~424` | `MapHomeCatSpeechBubble.displayText(action:fallback:)` — **`board.text`(AI 말풍선) → `MapHomeDefaultBubblePool.phrase(for:at:language:)`(3순위 기본 풀) → 동작 이름** 순서 | event/routine이 없을 때의 폴백은 여기. 이 순서는 그대로 |
| `MapHomeMapAnnotations.swift:531~556` | `MapHomeCatBubbleState` — `isCollapsed`, `toggleIfTapped(viewportPoint:)`(손가락 여유 8pt, 누르면 「…」로 접기/펼치기) | 말풍선을 누르는 **이미 있는 조작**. 연출 중 탭이면 즉시 넘김(2절 2항) |
| `TaptionPlan/UI/MapHomeView+Map.swift:683` | `handleMapTap`이 화랑이 탭보다 먼저 `toggleIfTapped`를 봄 | 탭 경로의 유일한 입구 |
| `TaptionPlan/UI/MapHomeDefaultBubblePool.swift:66~79` | `phrase(for:at:language:seasonPhrases:)` — 대분류·30분 칸으로 고정, 시즌 대사가 앞에 붙음 | 3순위는 손대지 않음(시즌 팩 대사 포함) |
| `TaptionPlan/UI/AssistantSettingsView.swift:136~171` | `AssistantActivityObserver`(지도 화면 위 0크기 뷰): `.task`에서 앱을 켤 때·날이 바뀔 때 `cleanExpired()` 후 **30초마다 `refresh()`** 루프. `.onChange(of: scenePhase)`는 지금 `.active`에서 활동 올리기만 함 | 지금 말풍선을 다시 고르는 유일한 주기 갱신(30초). 10초 전환에는 너무 느림 |
| `AssistantSettingsView.swift:224` | 그 관찰자가 `MapHomeView.assistantLayers`의 overlay에 붙고, **`if TripRelay.isAvailable` 안**에 있음 | 부착 조건. 이 조건은 이번에 바꾸지 않음(범위 밖) |
| `TaptionPlan/UI/AppShellView.swift:109~110` → `:445` `handleScenePhaseChange(_:)` | 앱 루트가 장면 단계 변화를 한 곳에서 받음 | 콜드 런치·백그라운드 복귀를 가르는 자리 후보 |
| `TaptionPlan/Core/FlightBubble.swift:21~26` | 항공편 말풍선을 `kind: .event`로 만들고 창은 「출발 4시간 전(그날 0시보다 앞서지 않게) ~ 출발」 | event가 **시간대 창을 갖는** 실제 사례. 창 밖에서는 연출 대상이 아님 |
| `TaptionPlan/UI/AssistantDataActions.swift:95~98` | `setBubble{날짜·시간대·문구·kind}` — event는 기본이 그날 0시~다음 날 0시 | 「하루 종일」 event가 어디서 생기는지 |
| `Packages/TaptionAssistant/Sources/TaptionAssistantProtocol/AssistantAppValues.swift:81` | `enum AssistantBubbleKind: String { routine, event }` | 종류 정의(패키지, 손대지 않음) |
| `TaptionPlanTests/AssistantPhase3Tests.swift:618`·`:641`·`:656` | 말풍선 창 선택·숨김·48개 한도, 종류 우선순위·지난 event 정리, `active(...)?.id == event.id`(「the day's event comes first」) | 새 시험을 여기에 붙이고, 기존 줄이 계속 통과해야 함 |
| `TaptionPlan.xcodeproj/project.pbxproj:222`·`:1132` | 시험 파일이 **파일마다** `PBXBuildFile`·`PBXFileReference`로 등록됨(동기화 그룹 아님) | 새 시험 파일을 만들면 pbxproj도 고쳐야 함 → 기존 `AssistantPhase3Tests.swift`에 붙이는 편이 안전 |
| `Packages/SeasonPackKit/Sources/SeasonPackKit/SeasonPackOverlay.swift:20` | 노래방 가사는 `center.stage.lyricText`로 **지도 위 별도 오버레이**에 그려짐(말풍선 보드와 무관) | 건드리지 않음. 다만 산타·가사와 겹쳐 보이는지는 실기기 확인 항목으로 |

## 2. 바꿀 동작 (계약 — 이 7항이 전부입니다)

1. **켤 때 먼저**: 앱이 전면으로 올 때(**콜드 런치**와 **백그라운드에서 복귀** 둘 다 「시작」) 오늘의 event 말풍선이 있으면, 그 순간에는 시간대 routine보다 **event를 먼저** 보여 줍니다. 조건은 지금 `active`와 같습니다 — `kind == .event`, `hidden == false`, `parsed != nil`, `start <= now < end`, 같은 날. **시간대 창이 있는 event(항공편 등)는 그 창 안에서만** 연출 대상입니다.
2. **한 번 보여 주고 넘김**: event는 시작할 때 **한 번만** 노출하고, **기본 10초**가 지나면 그 시각의 routine 말풍선으로 자동 전환합니다. 10초는 **상수 하나**(예: `AssistantBubbleBoard.launchRevealSeconds`)로 조정 가능해야 하고, 다른 곳에 10을 흩어 쓰지 않습니다. **이미 있는 「말풍선 누르기」(지도 탭 → `MapHomeCatBubbleState.toggleIfTapped`)로도 즉시** 넘어가야 합니다 — 연출 중 탭이면 그 탭은 「접기/펼치기」가 아니라 **연출 종료**로 처리하고, 그다음 탭부터 지금처럼 「…」 접기/펼치기가 됩니다. `AssistantBubbleLinkBar`의 `xmark`(영구 숨김)는 지금 의미 그대로입니다.
3. **같은 실행 중 재발 없음**: 한 번 넘어간 뒤에는 **그 실행이 끝날 때까지** event로 되돌아가지 않습니다. 30초 `refresh()` 루프, `replace()`(저장), 목록 재읽기 어느 경로로도 event가 다시 1순위가 되면 안 됩니다. 앱을 다시 켜면(전면 진입) 다시 event부터입니다.
   - 「시작」의 경계: `.background → .active`와 콜드 런치만 새 시작입니다. 알림 센터·제어 센터처럼 `.inactive`만 다녀오는 것은 새 시작이 아니고, 지도 화면이 다시 만들어지는 것(탭 전환·시트 닫기)도 새 시작이 아닙니다.
   - 보안 잠금 화면·첫 실행 안내가 지도를 덮은 채 시작하면, 연출은 **지도가 실제로 보이는 순간**에 시작합니다(가려진 10초를 쓰지 않음).
4. **여러 개면 하나**: 오늘 event가 여럿이면 지금 규칙 그대로 **늦게 시작한 것 하나**(`max { $0.start < $1.start }`)만 연출합니다. 새 규칙을 만들지 않습니다.
5. **없으면 기존 그대로**: event가 없으면 지금과 똑같이 `routine → MapHomeDefaultBubblePool(대분류 기본 풀) → 동작 이름` 순서입니다. 시즌 팩 대사가 기본 풀 앞에 붙는 것도 그대로입니다.
6. **지난 event 정리**: `isExpired`/`cleanExpired`(그날 끝이 지나면 지움)는 그대로. 연출 상태 때문에 지우는 시점이 달라지면 안 됩니다.
7. **기존 용도 보존**:
   - **재생·사이드바 핸들**(`viewedTime != nil`): 연출하지 않고 지금처럼 그 시각의 event/routine을 그대로 고릅니다. 연출 중에 과거 시각으로 옮기면 연출은 즉시 취소됩니다. `show(at: nil)`로 지금으로 돌아오면 새 시작 전까지 연출 없음.
   - **노래방 가사**(`SeasonPackKaraokeBubble`)·**하루 48개 한도**·**`AssistantBubbleArchive` 미러**·**숨김(hidden)** 동작은 그대로.
   - 연출 중에 그 event가 숨겨지거나(링크 줄 `xmark`), 창이 끝나거나, 지워지면 **즉시 routine으로** 넘어갑니다(없으면 기본 풀).

## 3. 구현 방향 (권장 — 시험하기 쉬운 모양으로)

3-1. **고르는 규칙은 순수 함수로** 꺼내 둡니다(시계·싱글턴 없이 시험). 예:

```swift
/// 오늘의 event 하나를 켤 때 한 번 보여 주고 시간대 말풍선으로 넘기는 규칙(BUB1120A01).
enum AssistantBubbleLaunchReveal {
    static let seconds: TimeInterval = 10
    struct Session: Equatable { var bubbleID: UUID; var until: Date }

    /// 켤 때 연출할 event. 오늘 것이 없으면 nil.
    static func start(at now: Date, in bubbles: [AssistantBubble],
                      calendar: Calendar = .autoupdatingCurrent) -> Session?
    /// 지금 보일 말풍선. 연출 중이면 event, 아니면 event 없는 `active`(routine).
    static func shown(at now: Date, in bubbles: [AssistantBubble], session: Session?,
                      calendar: Calendar = .autoupdatingCurrent) -> AssistantBubble?
}
```

`AssistantBubbleStore.active(at:in:)`는 **기본 동작을 그대로** 두고, event를 빼는 선택이 필요하면 매개변수(예: `includingEvent: Bool = true`)나 별 함수로 얹습니다. `AssistantPhase3Tests.swift:656`(「the day's event comes first」)이 계속 통과해야 합니다.

3-2. **보드 세션 상태**: `AssistantBubbleBoard`에 `@ObservationIgnored private var launchReveal: AssistantBubbleLaunchReveal.Session?`과 취소 가능한 `Task`(또는 `Task<Void, Never>?`)를 두고, `refresh(now:)`가 `launchReveal`을 보고 `active`를 고릅니다. 세션은 **보드에만** 있고 파일·백업·서버에 저장하지 않습니다(다음 실행은 새 세션).

3-3. **시작 훅**: 전면 진입을 아는 자리에서 `beginLaunchReveal(now:)`(가칭)를 부릅니다 — 후보는 **지도 화면 부착 지점**(`AssistantSettingsView.swift:136~171`의 `AssistantActivityObserver`가 붙는 자리, `:224` `assistantLayers` overlay)입니다. `AppShellView`는 **동결 파일이라 고치지 않습니다**(7절). `AppShellView.swift:109~110` → `:445`는 **읽고 참고만** 합니다(장면 단계가 어디서 들어오는지 확인하는 용도). 지켜야 할 것:
- **지도가 보이지 않을 때(잠금·첫 실행 안내·시트가 전부 덮음) 시작하지 않습니다.**
- 같은 시작에서 두 번 불려도 한 번만 시작합니다(멱등).
- 알림 센터·제어 센터처럼 `.inactive`만 스친 경우, 지도 뷰가 다시 만들어지는 경우에는 시작하지 않습니다.
- `viewedTime != nil`이면 시작하지 않습니다.

3-4. **10초 타이머**: 30초 루프 간격을 줄이지 말고, 연출을 시작할 때 `Task { try? await Task.sleep(...); refresh() }` 하나를 띄우고 다음 시작·`show(at:)`·`replace`에서 취소합니다. `refresh` 안에서도 `until`을 함께 보므로 타이머가 늦거나 취소돼도 다음 갱신에서 바로잡힙니다. `Timer`·`DispatchQueue.main`·새 의존성·새 패키지는 쓰지 않습니다(`docs/architecture-baseline.json` 검사 대상).

3-5. **탭**: `MapHomeCatBubbleState.toggleIfTapped`에서 「연출 중이면 연출 종료하고 true(다른 탭 판정으로 넘기지 않음)」를 먼저 봅니다. 보드의 연출 상태는 `MapHomeCatBubbleState`가 직접 만지지 말고, 보드에 「연출 끝내기」 하나를 두고 부릅니다(결합을 늘리지 않음). 탭이 없을 때 쓰는 8pt 여유·접기 동작은 그대로.

3-6. **문서 주석**: `AssistantBubble.swift:118~120`의 「event는 그날 하루 맨 앞」 주석을 새 규칙으로 고치고, 같은 자리에 `BUB1120A01`을 적습니다. `AGENTS.md` 4절에 오래 지킬 결정 한 줄을 넣습니다(5절).

## 4. 시험 (`TaptionPlanTests`)

**기존 파일 `AssistantPhase3Tests.swift`에 붙입니다**(pbxproj 등록 불필요, 말풍선 시험이 이미 있는 자리). 새 파일로 만들면 `project.pbxproj:222`·`:1132` 모양대로 등록해야 합니다. 시계는 인자로 넣어 실제 시간에 기대지 않게 합니다.

1. `testLaunchRevealShowsTodaysEventFirst` — 오늘 0~24시 event + 09~10 routine이 있고 09:30에 시작하면 event가 보인다.
2. `testLaunchRevealMovesToRoutineAfterTenSeconds` — 같은 목록에서 시작+10초(상수 기준)에는 routine, event는 보이지 않는다. 상수를 바꿔도 시험이 그 상수를 읽어 판정한다.
3. `testLaunchRevealDoesNotRepeatWithinOneRun` — 한 번 넘어간 뒤 같은 세션에서 여러 번 다시 골라도 event가 돌아오지 않는다(30초 갱신·저장(`replace`) 경로 포함). 새 세션을 시작하면 다시 event.
4. `testLaunchRevealWithoutEventKeepsCurrentOrder` — event가 없으면 routine이 그대로, routine도 없으면 `nil`(보기에서는 기본 풀). 재생 시각(`viewedTime` 상당)에서는 연출하지 않는다.
5. `testLaunchRevealPicksOneOfSeveralEvents` — 오늘 event가 둘이면 늦게 시작한 하나만.
6. `testLaunchRevealEndsWhenEventBecomesInvalid` — 연출 중 `hidden`이 되거나 창이 끝나면 즉시 routine으로.

**기존 시험**: `AssistantPhase3Tests`의 말풍선 시험(`:618`·`:641`)과 `AssistantReviewFixTests`·`AssistantCommandEditTests`의 말풍선 관련 줄이 그대로 통과해야 합니다. 실제 실행 수·실패·건너뜀은 xcresult로 확인해 회신에 적으십시오. `-only-testing:TaptionPlanTests`로 돌리고, 동작 코드를 바꾸므로 앱 Debug 빌드까지 합니다(`AGENTS.md` 5절 빌드 잠금·시뮬레이터 규칙 그대로).

## 5. 기록·문서

1. `test.md` `## 남은 작업` 「홈·UI」에 한 줄, `### 요청 상세`에 원인(「event가 하루 종일 1순위라 routine을 가림」)·해결(2절 요약)·검증 기준·**대표 결정 2026-11-20**.
2. 끝나면 그 줄과 상세를 지우고 `## 검증 기록` 맨 위에 결과 절(`### BUB1120A01 · 일정 말풍선 켤 때 한 번 → 시간대 말풍선 (날짜, 시뮬레이터 iPhone 17)`)을 씁니다(`AGENTS.md` 2절).
3. `test.md` `## 실기기 확인 목록` 「아이폰 11 Pro」에 한 줄: 「오늘 event 말풍선이 있는 상태에서 앱을 완전히 종료했다가 켬 → event 문구가 먼저 보이고 약 10초 뒤 그 시각의 시간대 문구(또는 기본 풀)로 바뀜. 말풍선을 누르면 곧바로 바뀜. 앱을 백그라운드로 보냈다 돌아오면 다시 event부터」.
4. `AGENTS.md` 4절 「대표 결정」에 오래 지킬 한 줄(문구 예): `- **말풍선 순서(2026-11-20, BUB1120A01)**: 일정(event) 말풍선은 앱을 켤 때 한 번만 먼저 보이고(기본 10초, 누르면 즉시) 그 시각의 시간대 말풍선으로 넘어간다. event는 하루 종일 붙잡지 않는다. 시간대·기본 문구 순서는 그대로.` 3절 「앱 UI는 앱 target」은 건드리지 않습니다.
5. **`Docs/pipeline/CHANGELOG.md`는 없습니다**(0-7절). 만들지 말고 위 1~3으로 기록합니다.

## 6. 확인 기준

- [ ] 콜드 런치·백그라운드 복귀에서 오늘 event가 있으면 **먼저** 보이고, 10초(상수) 뒤 routine으로 넘어간다. routine이 없으면 기본 풀 문구가 보인다.
- [ ] 같은 실행에서 event가 두 번 다시 뜨지 않는다(30초 갱신·저장·재읽기 모두).
- [ ] 말풍선을 누르면 연출이 즉시 끝나고, 그다음 누름부터 지금처럼 「…」 접기/펼치기다.
- [ ] event가 없을 때 화면이 지금과 **완전히 같다**(문구·30분 칸·시즌 대사 포함).
- [ ] 재생·사이드바 핸들로 과거 시각을 볼 때의 표시가 그대로이고, 연출 중에 옮기면 연출이 취소된다.
- [ ] 지난 event 정리·48개 한도·백업 미러·숨김이 그대로 동작한다.
- [ ] 4절 시험 6건과 기존 말풍선 시험이 통과하고, 실제 수치(실행·실패·건너뜀)가 회신에 있다.
- [ ] `test.md`(남은 작업 → 검증 기록, 실기기 확인 목록)와 `AGENTS.md` 4절이 5절대로 갱신돼 있다.
- [ ] 시작할 때 같은 변경이 이미 `main`에 들어가 있으면(켤 때 한 번 보여 주고 넘기는 규칙이 이미 있으면) 중복으로 고치지 말고 그 커밋·상태만 회신하고 이 문서를 `done/`으로 옮깁니다.

## 7. 하지 말 것

- **`AssistantBubbleStore.active(at:in:)`의 기본 의미 바꾸기** — 기존 시험이 「그 시각엔 event가 먼저」를 확인합니다. 새 규칙은 보드/순수 함수 층에 얹습니다.
- 말풍선 글 규칙(80자·링크 3개·줄 수·폭), 하루 48개 한도, `isExpired`/`cleanExpired`, `AssistantBubbleArchive` 미러, `hidden` 의미, 대분류 기본 풀 순서·30분 칸, 시즌 팩 대사, 노래방 가사 말풍선 손대기.
- `AssistantBubbleLinkBar`의 `xmark`를 「연출 종료」로 바꾸기(그것은 **영구 숨김**입니다).
- `if TripRelay.isAvailable` 부착 조건 바꾸기, 중계 서버·`validate.js`·배포 손대기.
- 30초 루프 간격을 통째로 줄이거나 1초 폴링 넣기(배터리·성능 상한, `AGENTS.md` 4절).
- `Timer`·`Task.detached`·`try!`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리기, `docs/architecture-baseline.json` 고치기, 동결 파일 5개 수정.
- 새 외부 의존성·유료 API·SDK·구독 도입(무과금).
- 다른 세션의 미커밋 변경을 이번 커밋에 넣기, 파일 삭제, TestFlight 업로드, 계정·결제.
- 지시서·회신에 개인정보·계정·서버 주소·실제 좌표·실제 동네/가게 이름 쓰기(공개 저장소, `AGENTS.md` 8절).

## 8. 회신에 담을 것 (`pickle-bridge/README.md` 4절 형식)

- 처리(완료/일부/막힘), 요청 ID, 시작·끝 시각, 커밋 해시(작업 커밋·문서 이동 커밋), 바꾼 파일.
- **연출 시간 상수 이름과 값**, 시작 훅을 붙인 정확한 위치(파일:줄), 「새 시작」으로 보는 경계(콜드 런치·백그라운드 복귀만인지)와 그 이유.
- 시험 결과 실제 수치(실행·실패·건너뜀, xcresult 경로)와 Debug 빌드 결과. 시뮬레이터와 실기기를 구분해 적기.
- 시뮬레이터에서 눈으로 본 화면(event → routine 전환, 탭으로 즉시 전환)과 **보지 못한 것**을 나눠 적기.
- `test.md`·`AGENTS.md` 4절 갱신 위치, 실기기 확인 목록 ID.
- `Docs/pipeline/CHANGELOG.md`가 없어 `test.md`로 대신했다는 한 줄(다르게 판단했으면 근거).
- 막혔으면 파일을 `done/`으로 옮기지 말고 `status: blocked` + 객관식 질문(추천을 첫째에).

## 참고

- 이 지시서 1절의 파일:줄은 2026-11-20 17:51의 `ed824ea8`에서 확인한 것입니다. 착수 때 `rg -n`으로 다시 확인하고, 달라졌으면 회신에 적으십시오.
- 관련 기록: `test.md` `BUB1110A01`(AI 말풍선 도입, 대표 결정), `BUB1110A02`(event/routine 종류·우선순위·정리), `BBL1111A01`(글 폭·줄 수), `BBL1111A02`(누르면 접기), `FLT1119A01`(항공편 event 말풍선), `SEA1120A01·A02`(시즌 팩 오버레이·산타).
- 규칙: `AGENTS.md` 2·4·5·6·7·8절, `pickle-bridge/README.md`. 성능 함정은 `DEVELOPMENT.md` 「자주 걸리는 함정」.

## 점검 회신 (비야, 2026-11-20 18:51)

- 3-3의 시작 훅 후보에서 **모순 하나를 고쳤습니다**: `AppShellView`를 후보로 적어 두고 7절에서는 같은 파일을 동결 파일로 금지하고 있었습니다. 이제 `AppShellView`는 **읽기 참고만** 하고, 훅은 지도 화면 부착 지점(`AssistantActivityObserver`·`assistantLayers`)에 붙입니다.
- 머리에 처리 순서를 넣었습니다: LAG1120A01 다음, RTA1120A01과 같은 커밋에 섞지 않기(LAG의 콜드 실행 측정을 오염시키지 않기 위해).
- 1절 표의 파일:줄은 2026-11-20 18:4x `origin/main`에서 **그대로 맞았습니다** — `AssistantBubble.swift` 118~120 주석·161·169~175·178·184·207~213·218~222·229~243·245·251·253~257·301, `MapHomeMapAnnotations` 403·419~424·531~556, `MapHomeView+Map` 683, `DefaultBubblePool` 66~79, `AssistantSettingsView` 136~171·224, `AppShellView` 109~110·445, `FlightBubble` 21~26, `AssistantDataActions` 95~98, `AssistantAppValues` 81, `AssistantPhase3Tests` 618·641·656, `pbxproj` 222·1132.
- 고치지 않은 것: 2절 계약 7항(10초·탭으로 즉시 넘김·같은 실행 재발 없음)·6절 확인 기준·7절 하지 말 것(영구 숨김 `xmark` 유지, 30초 루프 유지)은 대표 지시·기존 결정이라 손대지 않았습니다.
