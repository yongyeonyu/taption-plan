---
id: 20261120-1805-realtime-screen-sync
created_at: 2026-11-20T18:05+09:00
status: pending
request_id: RTA1120A01
title: 통화 중 지시가 앱 화면에 바로 나타나게 — 앱 전면 실시간 반영(기본 3초·통화 중 1초)
from: 비야
basis: 대표 직접 지시 (2026-11-20 통화) — 「화면이 실시간으로 바뀌는 게 보여야 돼. 예를 들어 여행 계획을 세우는데, 비행기를 10시에 인천 공항에서 출발해서 2시에 하네다 공항으로 도착한다, 라고 얘기를 하면 그게 바로 보여야 돼. 앱에서.」 / 같은 통화에서 새로 고침 빈도를 직접 물으시고 정한 값(기본 3초, 통화 중 1초)
---

## 0. 이 요청의 범위 (먼저 읽기)

대표 요청은 한 번 정정됐습니다. 처음 전달된 것은 「에이전트 지시 기록(로그) 화면」이었고, 대표가 바로 정정했습니다: **「아니, 화면이 실시간으로 바뀌는 게 보여야 돼. … 그게 바로 보여야 돼, 앱에서.」**

- **만드는 것**: 앱이 전면에 있는 동안 중계 서버의 새 명령·계획을 짧은 간격으로 받아 **열려 있는 화면에 리로드 없이** 반영하는 경로. 기본 3초, 통화 중 1초(끔/3초/1초 세 값). 새로 들어온 항목은 잠깐 강조. 편집 중 항목 보호·중복 반영 방지. 실패는 그 자리에서 짧게 표시.
- **만들지 않는 것**: **지시 기록·로그 화면.** 이미 「AI 연결 › AI가 한 일」이 있습니다(`TaptionPlan/UI/AssistantSettingsView.swift:30`, `AssistantActionLog`·`AssistantActionLogView`). 로그를 새로 만들지 않고, 필요하면 목록 맨 위에 「방금 반영됨」 강조만 얹습니다(선택 사항 한 줄).
- **서버는 손대지 않습니다.** 폴링은 앱만 고쳐 됩니다. 밀어주기(WebSocket/SSE)와 서버 푸시 변경은 11절의 **대표 승인 대상**입니다.

## 1. 대표 시나리오 — 이것이 합격선

1. 대표가 앱에서 **여행 화면(여행 계획·일정)을 열어 둔 상태**로 통화한다.
2. 통화로 「인천공항 10시 출발, 하네다 2시 도착」이라고 지시하면, 비서(AI)가 `POST /command`(항공편 구간) 또는 `POST /plan`(여행 계획)으로 그것을 보낸다.
3. **앱을 다시 켜거나 당겨서 새로고침하지 않아도** 그 구간이 여행 일정 줄로 **수 초 안에** 나타난다. 나타난 줄은 「방금 들어왔다」가 보이게 잠깐 강조된다.
4. 앱이 백그라운드이거나 화면이 꺼져 있으면 확인은 **완전히 멈춘다**(배터리).

「수 초」의 기준값: 3초 모드에서 **보통 3~4초, 최대 6초**(확인 주기 + 왕복 + 적용). 1초 모드에서 **1~2초**. 이 값을 12절에서 실측해 회신에 적습니다.

## 2. 지금 저장소에서 확인한 사실 (2026-11-20 17:55, `origin/main` `ed824ea` 기준 — 착수 때 `rg`로 다시 확인하고 쓰십시오)

| 곳 | 지금 있는 것 | 이번에 볼 점 |
|---|---|---|
| `TaptionPlan/UI/MapHomeView+Support.swift:228~241` | 전면 폴링이 **이미 있다**: `.task(id: scenePhase == .active)` 안에서 10초마다 깨어 `AssistantCommandPolling.nextInterval`과 비교해 `AssistantCommandRefresh.now` 호출 | **지도 홈 화면 안에만** 있다. 다른 화면을 크게 열면 이 루프가 도는지 기기에서 확인해야 한다 |
| `Packages/TaptionAssistant/Sources/TaptionAssistantKit/AssistantCommandTransport.swift:75~117` | `AssistantCommandPolling`: 평소 `idleInterval 300`, 대화 중 10초, 저전력 20초, 과열 60초. 대화 판정은 서버 응답 머리 `x-ai-seen-ago`·`x-ai-ended`(5분) + 직접 새로고침 2분(`manualWindow 120`) | **이 값이 이번에 바뀐다**(4절). 옛 주석의 「대표 결정」 문구도 함께 고친다 |
| `MapHomeView+Support.swift:230~238` | 깸이 **10초 고정**(`Task.sleep(for: .seconds(10))`)이고 그 안에서 간격만 다시 본다 | 1초·3초를 만들려면 깸 자체를 간격에 맞춘다 |
| `TaptionPlan/UI/AssistantCommandRunner.swift:88~` (`run`) | 명령 받기 → 키 필터 → 확인 필요 판단 → 반영 → 결과 보고 → 하루 기록 올리기 | 그대로 재사용한다(새 반영 경로를 만들지 않는다) |
| `AssistantCommandRunner.swift:234~272` (`AssistantCommandRefresh.now`) | 확인 한 번에 **무거운 곁일**이 붙어 있다: `AssistantPush.syncRegistration`, 질문 올리기, `AssistantRuleStore.sync`, `AITaskQueue.refresh`, `ReceiptPhotoWatcher.startIfNeeded`, `ReceiptPhotoScanner.scan` | 1초 폴링에 이걸 다 붙이면 안 된다(4절 ⑤) |
| `AssistantCommandRunner.swift:274~` (`AssistantPush`)·`:177~` (`runInBackground(force:)`) | APNs 푸시로 깨어 같은 확인을 즉시 도는 길이 이미 있다(PSH1114A06) | 서버가 실제로 `cmd` 푸시를 보내는지 확인(11절) |
| `TaptionPlan/UI/AssistantCommandRunner.swift:1~80` (`AssistantCommandJournal`)·`AssistantCommandTransport.swift:1~22` (`AssistantCommandLedger`)·`run`의 `claimed` | 중복 방지·미보고 결과 재전송 장치가 이미 있다(장부 200 id, outbox 200, 도중 종료 시 `interrupted`) | 간격을 줄여도 **같은 id가 두 번 반영되지 않아야** 한다(시험) |
| `TaptionPlan/UI/AssistantCommands.swift:295~303` (`fetchCommands`) | `GET /command`가 **204면 본문 없음**, 200이면 목록 | 빈 큐일 때 비용은 머리뿐(5절). 새 조건부 요청 규격을 만들지 않는다 |
| `TaptionPlan/UI/TripRelay.swift:8~20` (`checkTripRelay`) | `/plan`은 **앱을 열 때·전면 복귀 때만** 확인하고, 처음 보는 내용이면 미리보기(`isTravelHomePresented`)를 띄운다 | 통화 중에는 안 뜬다 → 여행 화면이 열려 있으면 같은 폴링에 넣는다(7절) |
| `MapHomeView+Support.swift:216~226` | `.task`·`.onChange(scenePhase)`에서 `checkTripRelay`·`checkAssistantCommands`·공지·시즌 팩·항공편 공유 확인 | 시작·전면 복귀 동기화는 그대로 두고 **그 위에** 짧은 간격을 얹는다 |
| `TaptionPlan/UI/TravelModeView.swift:195·333` | 여행 화면이 `model.settings.travelTrips`·`travelTripItems`를 직접 읽는다(@Observable) | 모델이 바뀌면 따라오는 구조. 실제로 따라오는지 기기에서 확인 |
| `TaptionPlan/UI/TravelMapTripEditorSheet.swift`·`TaptionPlan/UI/TripImportSheet.swift` | 편집·가져오기 화면은 **지역 상태**를 들고 있다 | 편집 중 보호(8절)의 대상 |
| `TaptionPlan/TaptionPlanApp.swift:108~114` | 루트에서 `scenePhase`를 본다. `AppShellView`는 **동결 파일**이라 여기에 화면 추적을 넣을 수 없다 | 폴링 시작·정지를 앱 수준에 두는 자리 |
| `AssistantSettingsView.swift:26~31` | 「AI가 할 수 있는 일 / AI가 한 일 / AI 규칙」 Section | 설정 세 값(끔/3초/1초)을 넣을 자리(10절) |
| `AssistantCommandRunner.swift`의 `runInBackground` 첫 줄 | `!model.isSceneActive`로 백그라운드 실행을 가른다 | 전면/배경 판정에 이미 있는 값을 쓴다 |

- 저장소 규칙: 동결 파일 5개(성능·구조 검사 대상), 새 파일 1,200줄 미만, `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리지 않기, `architecture-metrics.py --check`·`check-app-engine-import-boundary.sh` 통과.
- **서버의 `POST /command`가 APNs `cmd` 푸시를 보내는지는 이 지시서에서 확정하지 않았습니다**(서버 코드를 열지 않음). 11절대로 확인만 하고, 없으면 서버 변경 승인 요청으로 남기십시오.

## 3. 설계 원칙 — 갱신 입구를 하나로

새 파일 하나에 앱 수준의 「살아 있는 확인」을 두고, **폴링이든 푸시든 같은 함수로 들어오게** 합니다(나중에 WebSocket으로 갈아끼울 때 호출부가 바뀌지 않게).

```
AssistantLiveSync (새 파일, 앱 target — 기존 UI 파일 관례 위치)
  start(reason:)        // 씬 .active 에서 시작, 폴링 Task 하나
  stop()                // .inactive/.background 에서 즉시 취소
  hold(_ screen: Screen) / release(_ screen:)   // 지금 열린 반영 대상 화면
  refresh(reason:) async   // ← 유일한 갱신 입구. 폴링·푸시·수동 새로고침이 모두 이리로
  interval(for mode:)   // 상수 하나로 계산(4절)
```

- 간격 값은 **상수 하나**(`agentSyncInterval`, 예: `enum AgentSyncMode: String { case off, three, one }`)에서 나오게 하고, 다른 파일에 3·1·300을 흩어 쓰지 않습니다.
- 겹치면 건너뜁니다: 기존 `AssistantRelayGate`·`isRunning`·`claimed`를 그대로 씁니다(같은 확인이 두 번 돌지 않게).
- `MapHomeView+Support.swift`의 지금 루프는 **이 입구를 부르는 쪽으로 바꿉니다**(지우고 다른 화면에만 붙이지 말 것 — 화면마다 다른 주기가 생기면 나중에 push로 갈아끼울 수 없습니다).

## 4. 폴링 명세 — 값과 근거

① **세 값만**: `끔 / 3초(기본) / 1초`. 설정 화면에 이 셋만 노출합니다(10절).
② **왜 3초가 기본**: 「수 초 안에 보인다」를 만족하면서 배터리·데이터가 감당되는 값. 1초는 통화 중처럼 「지금 눈으로 확인하는」 순간에만 씁니다.
③ **1초가 최소**: 1초보다 촘촘히(0.5초 등) 보내도 체감 지연은 줄지 않습니다(왕복 0.1~0.5초 + 적용 <1초). 더 잦은 폴링은 부담만 늘리므로 **0.5초 이하 값은 만들지 않습니다**.
④ **깸을 간격에 맞춘다**: 지금은 10초마다 깨어 간격을 재지만, 1초·3초를 만들려면 `Task.sleep` 자체를 그 간격으로 겁니다. 남은 시간이 없으면 다음 회차를 건너뜁니다(요청 쌓임 금지).
⑤ **무거운 곁일은 떼어 낸다**(중요): 3초·1초 확인에서는 **명령 받기·적용·결과 보고·여행 계획 확인**만 합니다. `AssistantRuleStore.sync`·`AITaskQueue.refresh`·영수증 스캔·질문 올리기는 지금의 5분 경로(또는 60초)에 그대로 두고, 짧은 폴링에서는 부르지 않습니다. 이걸 떼지 않으면 1초 폴링이 사실상 1초마다 5개 요청을 보내게 됩니다.
⑥ **변경 없음일 때 본문 최소**: `GET /command`·`GET /plan`은 빈 큐에 204(본문 없음)를 줍니다(`AssistantCommands.swift:301`). **새 ETag/`updatedAt` 규격을 만들지 않습니다** — 서버 변경이 되기 때문입니다. 이미 204면 충분합니다.
⑦ **전면·화면 열림에서만**: `scenePhase == .active`이고 반영 대상 화면이 하나라도 열려 있을 때만 돕니다. `.inactive`/`.background`에서 Task를 취소해 **요청 0건**.
⑧ **저전력·과열 완화**: 저전력 모드에서 1초는 3초로, 열이 `.serious`/`.critical`이면 10초로 낮춥니다(기존 정책 유지). 설정 줄에 「저전력에서는 3초」 안내를 작게 붙입니다.
⑨ **요청 하나의 상한**: 기존 `commandFetchTimeout` 5초·`singleAttempt` 유지. 401·429는 지금처럼 즉시 중단하고 8·9절대로 표시.

## 5. 비용 — 계산치(실측으로 대체할 것)

요청 1회 = 요청 머리 + 응답 머리, 빈 큐면 본문 0(204). 명령·계획이 있을 때만 본문 2~3KB가 붙습니다.

| 간격 | 시간당 요청 | 머리만일 때(회당 약 0.8~1.5KB) | 본문이 붙을 때(회당 +2~3KB) |
|---|---|---|---|
| 1초 | 3,600회 | 약 **3~5MB/시간** | 해당 회차만 +2~3KB |
| 3초 | 1,200회 | 약 **1~2MB/시간** | 같음 |
| 5분(지금 평소) | 12회 | 약 20KB/시간 | 같음 |

- 대표께 드린 설명과 같은 선입니다: **1초 상시는 시간당 수 MB**가 나갑니다. 그래서 1초는 **통화 중 빠른 모드**로만 두고, **켜면 30분 뒤 자동으로 3초로 돌아옵니다**(비야 제안 — 통화가 끝났는데 1초가 남는 것을 막습니다. 대표가 「계속 1초」를 원하시면 그 선택지를 더합니다).
- 위 표는 **계산치**입니다. 12절에서 기기에서 잰 값(배터리 %·데이터 바이트)으로 대체해 회신에 적으십시오. 세션 재사용(TLS) 때문에 실제 바이트는 표보다 작을 수 있고, 배터리는 요청 수보다 무선 wake-up 횟수가 좌우합니다.

## 6. 화면 반영과 「방금 들어왔다」 표시

① **반영 경로**: 지금의 `run` → `applyAssistantCommands` → `AppModel` 변경 → 열린 화면이 따라오는 흐름을 그대로 씁니다. 새 반영 경로를 만들지 않습니다.
② **따라오지 않는 화면을 찾아 고치는 것이 이번 일의 절반**입니다. 확인 대상: 지도 홈, 여행(여행 모드·계획 표), 하루 카드·일정, 가계부. 화면이 자기 사본을 들고 있으면(편집·가져오기 화면) 8절 규칙을 적용합니다.
③ **강조**: 새로 들어온 항목만 1회, **1.2초 정도** 배경/테두리 강조 + 가벼운 햅틱 1회. 이미 있는 강조 표현이 있으면 그것을 쓰고, 없으면 최소한으로 새로 그립니다. 대표가 **지금 보고 있는 화면에서만** 강조합니다(다른 화면에서 반짝이지 않게). 설정에서 끌 수 있게 합니다.
④ **알림 줄**: 이미 있는 `AssistantInbox.current.show(...)`(반영 결과 한 줄)를 그대로 씁니다. 새 배너 체계를 만들지 않습니다.
⑤ 화면 갱신만으로 값이 바뀌지 않는 경우(예: 포커스·스크롤 위치)는 건드리지 않습니다. 「리로드 없이 값이 바뀐다」가 목표이고, 화면 구조를 새로 만드는 것이 아닙니다.

## 7. 여행 계획(`/plan`)과 항공편 시나리오

지금 `/plan`은 앱을 열 때만 확인하고 미리보기 시트를 띄웁니다(`TripRelay.swift:8~20`). 그래서 통화 중에는 보이지 않습니다.

① **여행 화면이 열려 있으면 `/plan`도 같은 폴링 주기로 확인**합니다(같은 `refresh` 입구). 여행 화면이 닫혀 있으면 지금처럼 열 때 확인합니다.
② 두 경우를 나눕니다.
   - **a) 항공편 구간이 명령으로 오는 경우**(`addTripStop`·`updateTripStop`·`setTripItemStatus` 등, 어떤 동작으로 오는지는 착수 때 확인): 지금처럼 **자동 반영 + ③ 강조**. 대표 시나리오의 기본 경로입니다.
   - **b) 여행 계획 전체가 `/plan` JSON으로 오는 경우**: **자동 덮어쓰기는 하지 않습니다**(대표가 앱에서 고친 내용을 지울 수 있음). 여행 화면 안에 「새 계획이 도착했어요 — 반영 / 나중에」 카드를 **수 초 안에** 띄우고, 「반영」이 지금 미리보기와 같은 결과가 되게 합니다.
   - 이 구분은 **비야 제안**입니다. 대표가 「통화 중에는 묻지 말고 바로 넣어라」를 원하시면 그 결정(대표 결정으로 기록)을 받아 b도 자동 반영으로 바꿉니다.
③ 같은 계획이 다시 뜨지 않게 하는 기존 규칙(`TripRelay.isNew`, 내용 해시)을 유지합니다. 폴링이 짧아져도 같은 계획 카드가 반복해서 뜨면 안 됩니다.

## 8. 편집 중 보호와 중복 반영

① **중복**: 같은 id는 한 번만 반영합니다. 지금의 `AssistantCommandLedger`(200 id)·`claimed`·`journal`을 그대로 쓰고, 간격을 1초로 줄인 상태에서 같은 명령을 3회 확인해도 반영은 1회인지 시험으로 고정합니다.
② **편집 중 항목**: 편집 시트가 열려 있거나 특정 항목을 고치는 중이면 그 항목은 **이번 반영에서 건너뛰고 다음 주기에 반영**합니다. 화면에 「편집 중이라 잠시 미뤘어요」 한 줄.
③ **충돌**: 대표가 5분 안에 직접 고친 항목은 서버 값이 와도 덮어쓰지 않고 「충돌」로 표시해 대표가 고르게 합니다(비야 제안 — 되돌릴 수 없는 덮어쓰기를 막는 쪽). 지금 「AI가 한 일」의 되돌리기(AIR1110A02)가 있으니, 되돌릴 수 있는 변경은 지금 규칙을 그대로 따릅니다.
④ 반영하지 않은 명령은 서버 큐에 그대로 두고 다음 회차에 다시 봅니다(지금 `run`의 동작). 거절 사유는 지금처럼 `/command/result`로 보고합니다.

## 9. 실패·지연을 그 자리에서 보이게

① 확인이 실패하면 조용히 넘기지 않습니다: 전면 상태에서 **연속 3회 실패**하면 반영 대상 화면 위에 짧은 한 줄(예: 「AI 연결을 확인하지 못했어요」)을 띄우고, 성공하면 사라집니다. 같은 줄은 **5분에 한 번만** 띄웁니다(깜빡임 방지).
② 401·키 폐기는 지금의 `revoked` 처리대로. 429는 즉시 멈추고 대표에게 알립니다(기존 규칙).
③ **로그 화면은 만들지 않습니다**(0절). 「AI가 한 일」에 이미 남는 것으로 충분합니다.
④ 토큰·카드번호·계좌번호·비밀번호는 표시·기록·로그 어디에도 남기지 않습니다. 새 저장소를 만들지 않고, 기존 마스킹 규칙(`AssistantRedaction`)을 그대로 씁니다.

## 10. 설정 — 끔 / 3초 / 1초

- 위치: 「AI 연결」 화면의 지금 Section(`AssistantSettingsView.swift:26~31`)에 한 줄 — `실시간 반영` 세그먼트 `끔 / 3초 / 1초`, 기본 **3초(켜짐)**.
- 1초를 고르면 「통화 중 빠른 모드」로 설명하고, 30분 자동 복귀를 한 줄로 안내합니다.
- 저장은 이 화면이 이미 쓰는 설정 저장 관례를 그대로 따릅니다(새 저장 형식·백업 형식 변경 없음).
- 새 문구는 `language.text` 리터럴로 넣고 `scripts/l10n/extract.py` → `check.py`까지만 돌립니다(`generate.py`는 메인 세션 몫).

## 11. 다음 단계 — 밀어주기(push). **이번에는 하지 않습니다**

① **APNs 푸시는 이미 있습니다**: `AssistantPush`(PSH1114A06)가 `cmd` 종류를 받으면 같은 확인을 즉시 돕니다. 그러니 **서버가 `POST /command`·`POST /plan` 때 그 푸시를 실제로 보내는지**만 확인하십시오(`server/trip-relay/README.md`와 서버 코드는 읽기만). 보낸다면 폴링은 예비로 남기고 push가 1순위입니다 — 그것이 대표가 물으신 「더 나은 길」입니다. 보내지 않는다면 그건 **서버 변경**이라 실행하지 말고 회신에 「서버 변경 승인 필요」로 적습니다.
② **WebSocket/SSE**: 중계 서버가 Cloudflare(Durable Object로 주인별 상태를 이미 들고 있음)라 붙일 수 있습니다. 이점 — 지연 0.1~0.3초(폴링 1초보다 짧고, 폴링이 못 맞추는 순간도 잡음), 요청 수 0(연결 1개 유지), 배터리·데이터 유리. 대가 — Worker·DO 코드 변경과 배포(대표 몫), 연결 유지 비용이 무료 한도 안인지 확인 필요, 앱이 백그라운드로 가면 연결이 끊겨 **결국 폴링 예비가 필요**합니다.
③ 그래서 이번 작업은 **폴링으로 먼저 붙이고**, push는 승인 뒤 다음 단계로 둡니다(대표 확정). 3절의 입구 하나(`AssistantLiveSync.refresh`)로 갈아끼울 수 있게만 해 두십시오.
④ **서버 워커·DO·R2·D1을 이번에 고치지 않습니다.** 승인 없이 배포하지 않습니다(`AGENTS.md` 12절).

## 12. 검증

**실기기**(기본은 아이폰 11 Pro, 대표 체감 확인은 아이폰 18 Pro Max — 두 결과를 구분해 적음):

1. 여행 화면을 열어 둔 채 비서가 항공편 구간(`addTripStop` 등)을 보내고 **줄이 나타나기까지의 초**를 잽니다. 3초 모드 3회, 1초 모드 3회, 가운데 값·범위. 비교용으로 **지금 동작**(대화 중 10초·평소 5분) 1회.
2. 앱을 백그라운드로 보낸 뒤 1분간 **확인 요청 0건**(앱 계측 카운터 또는 프록시 로그). 화면을 끈 상태도 같게.
3. **1시간 열어 둔 상태**의 배터리 %·데이터 바이트: 3초 1회, 1초 1회(전후 값).
4. 편집 중 보호: 편집 시트를 연 채 명령을 보내 → 편집 내용이 유지되고 그 항목만 다음 주기에 반영.
5. 실패 표시: 비행기 모드 30초 → 한 줄 표시, 해제하면 사라짐.
6. `/plan` 계획 카드가 여행 화면 안에 수 초 안에 뜨고, 반영 뒤 같은 계획이 다시 뜨지 않음.

**단위 시험**(최소):

1. 명령 도착 → 모델에 반영되고 열린 화면이 관찰자 알림을 받는다(가짜 전송·가짜 시계).
2. 같은 id를 1초 간격 3회 확인해도 반영은 1회.
3. 편집 중 항목은 건너뛰고 다음 주기에 반영.
4. `scenePhase != .active`면 확인 함수가 불리지 않는다(호출 횟수 0).
5. 간격 상수: 끔/3초/1초가 그대로 쓰이고, 저전력·과열에서 완화 값이 나온다.
6. 짧은 확인이 무거운 곁일(규칙 동기화·영수증 스캔)을 부르지 않는다(대역으로 호출 횟수 확인).
7. `/plan` 새 계획이 카드로 뜨고, 같은 해시는 다시 뜨지 않는다.

**회귀**(깨지면 안 되는 것):

- 시작·전면 복귀 동기화(`MapHomeView+Support.swift:216~226` 경로)와 홈 진입 직후 반영.
- `/command/result` 보고와 큐 삭제(`postResults`·`deleteCommands`), 미보고 결과 재전송(`journal` outbox).
- 중복 방지 장부(200 id)와 `interrupted` 처리.
- 말풍선 하루 48개 한도(`AssistantBubble.dayLimit = 48`, BUB1110A02).
- 백업 미러·설정 파일 저장 경로(`AppSettingsFile`)의 형식 변화 없음.
- `swift test --package-path Packages/TaptionAssistant`(있다면)·앱 Debug 빌드·`-only-testing:TaptionPlanTests` 실제 실행 수·실패·건너뜀을 xcresult로 확인해 적기. 구조 검사 2종 통과.

## 13. 문서·기록

- `test.md`: 요청 ID **RTA1120A01** — `## 남은 작업` 「AI·PCC」에 한 줄, `### 요청 상세`에 원인·해결·검증 기준, `## 검증 기록`에 결과 절(실행 명령·측정값). **`docs/pipeline/CHANGELOG.md`는 저장소에 없습니다**(2026-11-20 확인). 새 이력 문서를 만들지 말고 `test.md` `## 검증 기록`에 남기십시오.
- `AGENTS.md` 4절에 **대표 결정**을 날짜와 함께 추가: 「2026-11-20: 앱 전면에서 AI 명령 확인 간격 기본 3초, 통화 중 1초(설정 끔/3초/1초), 백그라운드·화면 꺼짐에서는 정지. 이전 SYN1111A03(대화 중 10초·평소 5분)을 대체.」 다른 결정은 건드리지 않습니다.
- `docs/AI_RELAY_PLAN.md`·`docs/ACTIVITY_RELAY_API.md`: 앱이 명령·계획을 확인하는 시점과 간격, 푸시와의 관계를 갱신(서버 규격 자체는 변경 없음).
- `PRIVACY.md`: 새로 보내거나 저장하는 것이 없으면 문구 변경 없음(확인만 하고, 좌표·계정이 늘지 않았음을 회신에 한 줄).

## 14. 하지 말 것

- **서버(`server/trip-relay`)·Worker·Durable Object·R2·D1 수정·배포, `wrangler` 실행, WebSocket/SSE 도입** — 이번 범위가 아니고 대표 승인 대상입니다.
- 지시 기록·로그 화면 신설, 새 배너·알림 체계. (「AI가 한 일」이 이미 있음)
- 유료 인프라·새 SDK·구독·과금이 생기는 변경.
- 동결 파일 수정: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`. 화면 추적이 필요해도 `AppShellView`를 고치지 말고 앱·씬 수준에 둡니다.
- `MapHomeView.swift` 본 파일에 `@State`·저장 속성 더하기.
- 지금 있는 폴링 줄을 지우고 일부 화면에만 새 주기를 붙이기(모든 화면이 3절의 **한 입구**를 쓰게).
- `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리기, `docs/architecture-baseline.json` 고치기.
- 다른 세션의 미커밋 변경(`TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`) 커밋 포함. 경로를 지정해 이번에 만진 파일만 커밋.
- 저장소(공개)에 실제 좌표·집·동네 이름·계정·메일·서버 주소·키 쓰기, 시험에 실제 데이터 넣기.
- 측정 없이 「실시간으로 된다」고 보고하기, 안 돌린 시험을 통과로 적기.

## 15. 회신에 담을 것 (`pickle-bridge/README.md` 4절 형식)

- 처리: 완료 / 일부 / 막힘 · 요청 ID(RTA1120A01) · 시작·끝 · 커밋 해시(작업 커밋·문서 이동 커밋)
- **어느 길을 골랐는지와 이유**: 폴링(앱만) / APNs 푸시(서버가 이미 보내는지 확인한 결과) / 둘 다, 그리고 WebSocket을 다음 단계로 남긴 판단
- **실측 표**: 3초 모드·1초 모드의 반영까지 걸린 초(3회, 가운데·범위)와 지금 값 비교
- **배터리·데이터**: 1시간 열어 둔 전후 값(3초·1초 각각)
- **백그라운드 정지 확인**: 1분간 요청 수
- 편집 중 보호·중복 반영·실패 표시 시험 결과
- 바꾼 파일, 검증(실행 수·실패·건너뜀·구조 검사 2종), 실기기 확인 목록 ID, 번역 대기 문구 수
- 서버 변경이 필요하다고 판단한 것(실행하지 않음)과 그 이유
- 막혔으면 파일을 `done/`으로 옮기지 말고 `status: blocked` + 객관식 질문(추천을 첫째에)

## 참고

- 이 지시서 2절의 파일:줄은 2026-11-20 17:55 `ed824ea`에서 확인한 것입니다. 착수 때 `rg -n`으로 다시 확인하고, 달라졌으면 회신에 적으십시오.
- 명령 규격: `docs/ACTIVITY_RELAY_API.md`, `docs/AI_RELAY_PLAN.md`, 서버 `server/trip-relay/README.md`(「`/command`」·「`/plan`」·「푸시」 절 — 읽기만).
- 지금 동작의 선례: `MapHomeView+Support.swift:216~241`, `AssistantCommandRunner.swift:1~272`, `AssistantCommands.swift:295~303`, `TripRelay.swift:8~20`, `AssistantCommandTransport.swift:1~117`.
- 이전 지시서: `pickle-bridge/done/20261119-2330-travel-flight-and-alert-parser.md`(여행 모드 항공편 조회·파서 — 대표 시나리오의 항공편 표시가 어디로 들어가는지 참고), `pickle-bridge/inbox/20261120-1747-launch-lag-season-pack.md`(시작 경로·측정 방식).
- 규칙: `AGENTS.md` 2·4·5·6·7·8·9·12절, 브리지 형식: `pickle-bridge/README.md`.
