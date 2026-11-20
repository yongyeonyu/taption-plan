---
id: 20261120-1820-realtime-websocket-sync
created_at: 2026-11-20T18:20+09:00
status: pending
request_id: RTA1120A02
title: 통화 중 지시가 화면에 즉시 — 중계 WebSocket(Durable Object Hibernation) 실시간 반영
from: 비야
basis: 대표 직접 지시 (2026-11-20 18:1x 통화) — 앞서 올린 RTA1120A01(폴링 3초 기본·통화 중 1초)은 그대로 두고, 그 위에 실시간 밀어주기를 얹으라는 지시. 설계 세부(라우트 모양·이벤트 규격·비용 계산 방식)는 비야 제안
---

## 0. 이 지시서의 위치 (먼저 읽기)

- **`RTA1120A01`(`inbox/20261120-1805-realtime-screen-sync.md`)을 먼저 처리하고, 그 위에 얹습니다.** RTA는 앱만 고쳐 폴링으로 붙였고, 11절에서 WebSocket을 「대표 승인 대상」으로 남겨 두었습니다. 이 지시서가 그 승인분입니다. RTA가 만든 **갱신 입구 하나(`AssistantLiveSync.refresh(reason:)`)·화면 추적(`hold`/`release`)·설정 세그먼트(끔/3초/1초)를 그대로 쓰고**, 그 입구에 **서버가 미는 소켓**을 하나 더 답니다.
- **폴링은 지우지 않습니다.** 소켓이 끊겼을 때의 대체 경로로 남깁니다(7절).
- **만드는 것**: 중계 워커 안에 Durable Object 하나(`RealtimeRoom`, SQLite) + `GET /rt/ws` 업그레이드 + 앱의 소켓 클라이언트. 명령·계획이 생기면 서버가 **가벼운 알림**(`cmd`·`patch`)만 밀고, 본문은 앱이 **기존 HTTP로** 가져갑니다.
- **만들지 않는 것**: 새 명령 규격, 새 로그·배너 체계, APNs 신설(이미 있음 — 9절), 공지·시즌·항공편 쪽 캐시(기존 것 재사용).
- **배포는 하지 않습니다.** 코드·시험·묶기(`--dry-run`)까지만 하고, `wrangler deploy`는 대표 확인 뒤입니다(8절).

**처리 순서(2026-11-20 점검)**: 파일 이름 순서로 `1805 RTA1120A01` **다음 다섯 번째**이고, A01을 끝낸 뒤에만 손대는 문서입니다. 특히 **`1820-국내선-항공편-카드-조회.md`(FLT1120A01)가 같은 날 production 배포를 승인받아 먼저 돌 수 있으므로**, 배포를 포함한 문서가 이 코드를 삼키는 경우를 8절 마지막 항목대로 확인하십시오(킄 없이 `GET /rt/ws` → **401**이면 라우트가 살아 있다는 뜻).

## 1. 대표 시나리오 — 이것이 합격선

1. 대표가 앱에서 **여행 화면을 열어 둔 채** 통화한다.
2. 「인천공항 10시 출발, 하네다 2시 도착」이라고 말하면 비서(AI)가 `POST /command`(항공편 구간) 또는 `POST /plan`(여행 계획)을 보낸다.
3. 서버가 그 순간 **같은 주인의 열린 소켓으로 `cmd`/`patch`를 민다.** 앱은 본문을 기존 `GET /command`·`GET /plan`으로 받아 **열려 있는 화면만** 갱신한다.
4. 체감: **0.3~0.8초**(서버 왕복 + 적용). 폴링 1초의 「1~2초」보다 짧고, 폴링이 놓치는 「명령 두 건이 한 주기에 겹치는 순간」도 순서대로 잡힌다.
5. 앱이 백그라운드·화면 꺼짐이면 소켓을 닫고 **아무것도 받지 않는다**(배터리).

## 2. 지금 저장소에서 확인한 사실 (2026-11-20 18:1x, `origin/main` `fdbd12e6` — 착수 때 다시 확인하고 쓰십시오)

**이 저장소에는 이미 같은 모양의 WebSocket 서버가 하나 있습니다.** 새로 발명하지 말고 그 자리를 보고 베끼십시오.

| 곳 | 지금 있는 것 | 이번에 볼 점 |
|---|---|---|
| `server/trip-relay/src/share.js:148` | `setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping","pong"))` — 글자 `ping`에 DO를 깨우지 않고 `pong` | **그대로 베낀다**(하트비트) |
| `share.js:695~706` (`connect`) | `this.ctx.acceptWebSocket(server, ["m:"+no])` → `serializeAttachment({no, at})` → `hello` → `{status:101, webSocket:client}`. 시험용 `env.SOCKETS?.pair()/response()` 대체 경로도 있다 | 접속·첨부·101 응답의 정본 |
| `share.js:708~735` (`webSocketMessage`→`socketOp`) | 글자 메시지만, `bodyBytes` 상한, `{op:..., id}` 규격, `since`로 밀린 것 따라잡기(`changes`) | 이벤트 규격·따라잡기 모양 |
| `share.js:736~750` (`webSocketClose`/`webSocketError`) | 닫힘 코드 정리(1005·1006→1000) | 그대로 |
| `share.js:773~783` (`roomRoute`) | Worker 쪽 진입: `roomStub(env, roomId).fetch(request)` 로 DO에 넘김 | `/rt/ws` 라우트도 같은 모양 |
| `wrangler.toml:73~81` | `SHARE_ROOM` 바인딩 + migration `v2-share-room`(`new_sqlite_classes`) | **`v3-realtime-room`을 하나 더** 붙인다. 이 파일은 공개용, 실제 배포는 맥의 `wrangler.local.toml`(git 제외) |
| `src/state.js:781~806` (`UserState`) | 주인마다 하나인 SQLite DO. 명령 큐·한도·푸시 토큰 | **손대지 않는다**(대안은 3절 끝) |
| `src/store.js:512~537` (`queueCommand`) | 큐에 넣고 `notify(ctx, pushForCommand(command))`(APNs) | 여기서 `cmd` 이벤트도 민다 |
| `src/store.js:56`(`savePlan`)·`:78`(polish)·`:127`(`/app`)·`:194`(`/tasks`)·`:363`(activity) | AI가 쓰는 저장 경로들. **`savePlan`은 푸시를 보내지 않는다** | 성공한 뒤 `patch`를 민다 |
| `src/apns.js:74~90` | `pushForCommand`·`notify` — AI 키가 쓴 것만, 실패는 삼키고 `ctx.defer`(waitUntil)로 응답을 늦추지 않는다 | **발행 함수도 같은 규칙**(비동기·실패 삼킴) |
| `src/index.js:559~597` (`authorized`) | `Authorization: Bearer <키>` → `resolveKey` → `admit` → `run`, 오류는 `json(…401/403)`, `ctx.defer` 제공 | `/rt/ws`도 이 문을 그대로 지난다 |
| `src/index.js:372~450` (`ROUTES`) | 정확 경로 표. `/command`·`/plan`·`/push/token` … | 여기에 `"/rt/ws"` 한 줄 |
| `Packages/TaptionTripShare/.../ShareTransport.swift:85~96` | 앱 쪽 `URLSessionWebSocketTask` 열기(`ws/wss` 치환, `maximumMessageSize`) | 소켓 여는 코드의 선례 |
| `Packages/TaptionTripShare/.../ShareSocketChannel.swift:63~70` | 글자 `ping` 보내기·`receive()` 고리 | 앱 하트비트 선례 |
| `ShareSessionTypes.swift:263~301` | `ShareBackoff`(1s→60s, jitter 25%), `pingInterval = 30` | 재연결·핑 값을 그대로 |
| `Packages/TaptionAssistant/.../TripRelay.swift:12~18` | 중계 주소는 `Info.plist`의 `TRIP_RELAY_HOST`(저장소에 주소를 쓰지 않는다) | `wss://<host>/rt/ws` |
| `Packages/TaptionAssistant/.../AssistantSharing.swift:43~` (`relayRequest`) | `Authorization: Bearer` + `x-bokki-client` 헤더 | 소켓 핸드셰이크도 같은 헤더 |
| `TaptionPlan/Core/DiagnosticsLogSupport.swift:364` | `TaptionPlanDiagnosticsLogger.shared.record(_:fields:)` | 지표는 여기에 |
| `server/trip-relay/test/fakes.mjs:121~125` | 시험용 가짜 `SOCKETS`(`pair`·`response`) | 서버 시험을 이걸로 쓴다 |
| `server/trip-relay/package.json` | `npm test` = `node --test test/*.test.mjs` | 새 시험 파일 `test/realtime.test.mjs` |

- 저장소 규칙: 동결 파일 5개, 새 파일 1,200줄 미만, `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리지 않기, `architecture-metrics.py --check`·`check-app-engine-import-boundary.sh` 통과, SwiftUI는 값이 바뀔 때만 갱신.
- **공개 저장소입니다.** 중계 주소(`workers.dev` 쪽 포함)·키·토큰·실제 좌표·집·동네 이름을 문서·코드·시험에 쓰지 않습니다.

## 3. 서버 설계 — Durable Object 하나, 라우트 하나

① **클래스**: `server/trip-relay/src/realtime.js`에 `export class RealtimeRoom`(SQLite 백엔드) 하나. `wrangler.toml`에
```toml
[[durable_objects.bindings]]
name = "REALTIME_ROOM"
class_name = "RealtimeRoom"

[[migrations]]
tag = "v3-realtime-room"
new_sqlite_classes = ["RealtimeRoom"]
```
같은 블록을 **맥의 `wrangler.local.toml`에도** 넣습니다(그 파일에만 실제 D1 id가 있고, 배포는 `--config wrangler.local.toml`로 합니다 — `server/trip-relay/README.md:150·183~185`). 빠뜨리면 「배포했는데 바인딩 없음」이 됩니다.

② **방 키는 주인 단위 하나**: `env.REALTIME_ROOM.idFromName("owner:" + ctx.master)`. `ctx.master`는 이미 주인 키의 **sha256**(`src/keys.js:57~63`)이라 원문이 아니고, **기기 ID를 새로 만들지 않습니다**(기기 식별자를 모으지 않는 쪽이 낫습니다 — 아래 ⑨). 한 주인의 여러 기기는 같은 방에 붙어 같은 이벤트를 받고, 각자 자기 화면만 갱신합니다.

③ **라우트**: `ROUTES`에 `"/rt/ws": { GET: ["master", realtimeRoute] }`.
- `master` 범위로 둡니다 — **앱(주인 키)만 붙습니다.** AI 연결 키가 소켓을 열 이유가 없습니다.
- `realtimeRoute(request, ctx)`:
  - `upgrade` 헤더가 `websocket`이 아니면 `426 upgrade_required`.
  - `env.REALTIME_ROOM`이 없으면 `503 unavailable`.
  - `env.REALTIME_ROOM.get(env.REALTIME_ROOM.idFromName("owner:" + ctx.master)).fetch(request)` — `ShareRoom`의 `roomStub`(`share.js:757·782`)와 같은 모양. 101 응답은 **그대로 통과**시킵니다(헤더 손대지 않기).
- 인증은 **기존 문**을 그대로 지나게 둡니다: `Authorization: Bearer <주인 키>` 헤더(`authorized`→`resolveKey`→`admit`). 인증 실패는 업그레이드 전에 **401**로 끝납니다. **쿼리에 토큰을 넣지 않습니다** — 저장소 규칙(비밀은 헤더·본문에만, `ShareTransport.swift:3` 주석)과 어긋나고 프록시·로그에 남습니다. 앱은 헤더를 넣을 수 있습니다(`AssistantSharing.relayRequest`가 이미 그렇게 합니다).

④ **Hibernation만 씁니다.**
- `this.ctx.acceptWebSocket(server)` (표준 `ws.accept()` 금지), `webSocketMessage`/`webSocketClose`/`webSocketError` 세 갈래를 정의.
- **`setTimeout`·`setInterval`·`setAlarm`로 하트비트를 만들지 않습니다.** 서버가 주기적으로 밀지 않고, 응답은 `setWebSocketAutoResponse`(`ping`→`pong`)가 DO를 깨우지 않고 돌려줍니다(`share.js:148`).
- 연결별 상태는 `serializeAttachment({ at, build })`로 보존하고 `deserializeAttachment()`로 읽습니다(작게 유지).
- 생성자에서 무거운 일을 하지 않습니다(hibernation 뒤 매번 다시 돕니다).

⑤ **이벤트를 미는 곳**: `realtime.js`에 `publish(ctx, event)` 하나를 두고, **AI가 쓴 것이 성공한 직후** 부릅니다. `notify`(`apns.js:90`)와 같은 규칙 — `ctx.defer(waitUntil)`, 실패는 삼킴, 응답 지연 없음.
- `ctx.auth?.kind === "master"`면 **발행하지 않습니다**(앱이 스스로 쓴 `/app`·`/activity` 업로드가 자기 화면을 다시 깨우는 고리를 막습니다 — `notify`와 같은 조건).
- `env.REALTIME_ROOM`이 없으면 **아무것도 하지 않고 조용히 돌아갑니다**(바인딩 없이 배포돼도 명령 저장은 그대로 동작해야 합니다).
- 부르는 자리(각 함수의 성공 반환 직전): `store.queueCommand` → `{type:"cmd"}`, `store.savePlan` → `{type:"patch", entity:"plan"}`, `store.saveActivity` → `entity:"day"`, `store.savePolish` → `entity:"memo"`, `store.saveAppState` → `entity:"app"`, `store.saveTasks` → `entity:"tasks"`, `rules.putRules`/`deleteRules` → `entity:"rules"`.
- `/command/result`·`/tasks/result`·`/session/end`·DELETE 경로는 **앱이 쓴 것**이라 발행하지 않습니다.
- 발행은 DO에 요청 1건을 더 씁니다(이벤트당 1건, 무료 한도 안 — 6절).

⑥ **이벤트 저장·따라잡기**:
- 방마다 **최근 200건만** 둡니다. id는 방 안에서 1씩 오르는 정수. 200건을 넘으면 가장 오래된 것부터 지웁니다(**지우기도 행 쓰기로 셉니다** — 6절).
- 접속: `?since=<마지막 이벤트 id>`(비밀이 아니므로 쿼리에 둬도 됨).
- 보내는 순서: ① `hello {latest, oldest, now}` → ② `since` 다음 것부터 **50건씩** `{type:"events", items:[…], more:bool}` → ③ `{type:"ready", latest}`.
- `since`가 `oldest`보다 작거나 `latest`보다 크면(저장소가 비었거나 앱이 오래됨) `{type:"resync"}`만 보내고 앱이 **전체 새로고침**하게 합니다.
- 앱이 스스로 더 받고 싶으면 `{"op":"since","since":N}` 한 가지 op만 받습니다. 그 밖의 글자는 **조용히 무시**(오류 응답 고리 방지). 메시지 길이 상한을 둡니다(`SHARE.bodyBytes` 참조).
- 이벤트 하나는 60바이트 안팎입니다(아래 5절).

⑦ **연결 수 상한**: 주인 방 하나에 기기 5개까지. 넘으면 가장 오래된 연결을 `bye`(4408 `replaced`)로 닫습니다(`share.js:698`의 `socketsPerMember` 처리와 같은 방식).

⑧ **비업그레이드 경로**: DO의 `fetch`에 Worker만 부르는 `POST /event`(발행) 하나를 둡니다. DO는 바인딩으로만 닿으므로 이 문은 밖에서 열리지 않습니다. 그 밖의 경로는 404.

⑨ **주인 신원은 DO 이름에서만** 읽습니다(`ctx.id.name`). 헤더·쿼리·본문으로 받은 사용자 값을 믿지 않습니다. **기기 ID를 저장하거나 로그에 남기지 않습니다** — 방 이름이 이미 주인 해시이고, 기기 구분이 꼭 필요하면 attachment에 해시 한 조각만 둡니다.

⑩ **대안과 판단(기록)**: 기존 `UserState`(같은 주인의 DO)에 소켓을 붙이면 이벤트당 DO 요청 1건이 없어지고 enqueue와 알림이 한 인스턴스 안에서 원자적이 됩니다. 이번에는 **새 클래스로 갑니다** — 인증·큐를 들고 있는 DO를 건드리지 않는 쪽이 위험이 작고, 요청 1건 차이는 7절 계산에서 무시할 수준입니다. 이벤트가 하루 수천 건을 넘으면 그때 합치는 것을 검토합니다.

## 4. 앱 설계 — 소켓 하나, 입구는 그대로

① **RTA1120A01의 `AssistantLiveSync`를 확장**합니다(새 입구·새 폴링 고리를 만들지 않습니다).
- `start(reason:)` → 설정이 켜져 있으면 **소켓을 연다**. `stop()` → **소켓을 닫는다**(`.cancel`). `scenePhase`가 `.active`가 아니면 소켓 0개.
- 소켓 클라이언트는 `AssistantSocket` 작은 래퍼 하나(`URLSessionWebSocketTask`)로 둡니다. `ShareTransport`(`:85~96`)·`ShareSocketChannel`(`:63~`)의 **모양만** 베끼고, **`TaptionTripShare`를 AI 경로로 끌어오지 않습니다**(패키지 경계 검사 `check-app-engine-import-boundary.sh`).
- 주소: `wss://<TripRelay.host>/rt/ws?since=<커서>`. 헤더는 `Authorization: Bearer <주인 키>` + `x-bokki-client`(기존 `relayRequest`와 같은 값). 주소를 코드에 쓰지 않습니다.

② **수신 처리**
- `cmd` → `refresh(reason: .socket)` 한 번. 그 뒤는 기존 `run` 경로 그대로(장부·중복 방지·결과 보고·여행 계획 확인).
- `patch` → **지금 열려 있는 화면에 해당할 때만** 그 화면이 쓰는 자료를 다시 읽습니다: `plan`→여행 계획(열려 있으면 `TripRelay` 확인 포함), `day`→오늘 하루 기록, `memo`·`app`·`tasks`·`rules`→각 저장소. **전체 새로고침 금지**, 무거운 곁일(영수증 스캔·질문 올리기·규칙 동기화) 금지(RTA 4절⑤와 같은 선).
- `resync` → 커서 0으로, RTA의 전체 확인 1회.
- `hello`의 `latest`는 커서를 앞당기는 데만 씁니다(이벤트를 건너뛰지 않게 **`events`를 다 받은 뒤** 갱신).
- 커서는 `UserDefaults`에 정수 하나(`assistantRealtimeCursor`). 토큰·키는 저장하지 않습니다.

③ **핑·재연결**
- 글자 `ping`을 **25~30초**마다(=`ShareSessionEnvironment.pingInterval` 30과 같은 값). 서버가 `pong`으로 답합니다.
- 끊기면 `ShareBackoff`(1s→60s, jitter 25%)로 다시 붙습니다. `since`는 마지막으로 받은 이벤트 id.
- **3회 연속 실패면 폴링 모드로 내려가고**, 30분마다 한 번만 조용히 다시 시도합니다. 401을 상태 코드로 구분하려 애쓰지 마십시오(`URLSessionWebSocketTask`는 상태 코드를 편하게 주지 않습니다) — 인증 폐기는 **기존 폴링 경로의 401 처리**(revoked)가 판정합니다.

④ **폴링과의 관계**
- 소켓이 살아 있으면 **짧은 폴링(3초·1초)을 멈추고** RTA의 5분 안전망(`idleInterval 300`)만 남깁니다.
- 통화 중에 소켓이 끊기면 **1초 폴링**으로 즉시 내려갑니다(RTA 규칙 그대로). 통화가 끝나고 소켓이 붙으면 소켓만 씁니다.
- 소켓이 한 번도 못 붙는 환경(프록시·사내망)에서도 앱은 **RTA 그대로 동작**해야 합니다.

⑤ **설정**: RTA의 「실시간 반영」 세그먼트(끔/3초/1초) **바로 아래**에 「실시간 동기화」 스위치 하나(기본 **켬**). 끄면 소켓을 열지 않고 폴링만. 세그먼트가 「끔」이면 스위치는 흐리게. 새 문구는 `language.text` 리터럴 → `scripts/l10n/extract.py` → `check.py`까지만(`generate.py`는 메인 세션 몫).

⑥ **진단 지표**: `TaptionPlanDiagnosticsLogger.shared.record`로 `realtime_connect`·`realtime_reconnect`(시도 횟수)·`realtime_events`(수신 수, 60초 묶음)·`realtime_down`(폴링 전환) 네 가지만. **좌표·토큰·이벤트 본문은 남기지 않습니다**(기존 규칙).

## 5. 이벤트 규격 (정확히 이 모양)

```jsonc
// 접속 직후
{"type":"hello","latest":412,"oldest":213,"now":1763630000000}
// 명령이 큐에 들어갔다 — 본문은 앱이 GET /command로 가져간다
{"type":"cmd","id":"c-8f1a","kind":"addTripStop","at":1763630000123}
// 항목이 바뀌었다 — 화면이 해당 자료만 다시 읽는다
{"type":"patch","entity":"plan","id":"trip-7","at":1763630000123}
// 따라잡기 묶음
{"type":"events","items":[{"e":411,"type":"cmd","id":"c-8f19","kind":"setBubble","at":1763629999000}],"more":false}
// 끝
{"type":"ready","latest":412}
// 커서가 너무 오래됐거나 저장소가 비었다
{"type":"resync"}
```

- `entity`: `plan` | `day` | `memo` | `app` | `tasks` | `rules`. `id`는 그 항목의 id(없으면 생략).
- `at`은 epoch 밀리초 정수(문자열 아님).
- 이벤트에 **본문·금액·좌표·이름을 싣지 않습니다.** 알림만 싣고 본문은 HTTP로 — 크기·과금·재전송 신뢰성 때문입니다.

## 6. 요금 — 지금 규모에서 월 0원 (근거: Cloudflare 공식 문서)

확인한 사실(2026-11-20, `developers.cloudflare.com/durable-objects/platform/pricing`·`/best-practices/websockets`):
- Durable Objects는 **Workers Free에서도 되고, SQLite 백엔드만** 됩니다. 무료: **요청 100,000/일**, **Duration 13,000 GB-s/일**. 한도를 넘으면 **그 종류의 동작만 실패**하고(일일 한도는 00:00 UTC 리셋) 다른 기능은 계속 돕니다.
- **연결 생성이 요청 1건**이고, **나가는 메시지는 무료**, 들어오는 메시지는 **20:1**로 셉니다(100건 = 5요청). `setWebSocketAutoResponse`가 처리하는 `ping` 응답은 **duration이 청구되지 않습니다**.
- **hibernation 중에는 duration이 청구되지 않습니다.** 표준 WebSocket API나 타이머를 쓰면 연결이 살아 있는 내내 청구됩니다.
- SQLite DO 무료: **행 읽기 5,000,000/일**, **행 쓰기 100,000/일**(삭제도 쓰기로 셈), 저장 5GB.

계산(대표 1명, 하루 전면 6시간으로 **넉넉히** 잡음, 핑 30초):
| 항목 | 하루 | 비고 |
|---|---|---|
| 핑 들어오는 글자 | 720건 → **36요청** | 6시간 ÷ 30초 |
| 연결 만들기 | **30요청** | 전면 전환 20 + 재연결 10 |
| 이벤트 발행 | **50요청** | 이벤트 50건 가정(많게 잡음) |
| 합계 | **약 116요청/일** | 한도 100,000의 **0.12%** |
| Duration | 이벤트 처리만 ≈ **0.7 GB-s/일** | 한도 13,000의 0.005% |
| 행 쓰기 | 이벤트 50 + 순환 삭제 ≈ **100행/일** | 한도 100,000의 0.1% |

- **함정 하나**: hibernation을 안 쓰고 연결 하나라도 계속 깨어 있으면 0.128GB × 86,400초 = **11,059 GB-s/일**로 하루 한도(13,000)에 육박합니다. **그래서 3절④의 「타이머·표준 API 금지」는 취향이 아니라 요금 조건입니다.**
- **폴링보다 요청이 적습니다**: 3초 폴링은 시간당 1,200요청, 소켓은 시간당 120핑(=6요청분). 실시간을 켜면 오히려 총량이 줍니다.
- 베타 소수가 붙어도 10명 ≈ 1,200요청/일입니다. **Free 안에서 월 0원.** Workers Paid($5/월) 전환은 **넘었을 때만, 그때도 대표 승인**입니다(0원 고정비 원칙, 2026-11-16 PostHog $0 잠금과 같은 선).
- 한도를 넘겨 소켓이 실패해도 앱은 **폴링으로 내려가므로 기능은 계속 됩니다**(7절 ④).

## 7. 실패했을 때 (조용히 멈추지 않게)

① 소켓 실패·재연결은 앱 안에서만 조용히 처리하고, **3회 연속 실패에서 폴링으로 전환**한 뒤 RTA 9절의 「AI 연결을 확인하지 못했어요」 한 줄 규칙을 그대로 씁니다(새 배너 없음).
② 서버는 발행 실패를 삼킵니다(발행은 편의, 정본은 큐). **이벤트를 놓쳐도 폴링이 5분 안에 따라잡습니다.**
③ `resync`를 받으면 앱이 전체 확인 1회 — 조용히 넘기지 않습니다.
④ 무료 한도 초과·DO 장애·배포 전(404) 모두 **앱은 폴링으로 정상 동작**해야 합니다. 이것이 이 설계의 안전판이고 시험 항목입니다.

## 8. 배포 — 대표 확인 뒤에만

- **하지 않는 것**: `npx wrangler deploy`. `wrangler.local.toml`의 migration `v3-realtime-room`은 **처음 배포할 때 한 번 적용되고 되돌릴 수 없습니다**.
- **해도 되는 것**: `cd server/trip-relay && npm test`(노드 시험), `npx wrangler deploy --dry-run --config wrangler.local.toml --outdir /tmp/relay-dry`로 **묶기·바인딩 확인만**(업로드 없음). 출력에서 `REALTIME_ROOM`·`v3-realtime-room`이 보이는지 회신에 적으십시오.
- 배포는 회신에 「대표 확인 필요」로 남기고, 대표가 승인하면 그때 올립니다. **서버를 먼저 올려도 앱은 그대로**(소켓 없으면 폴링), **앱을 먼저 올려도 그대로**(`/rt/ws` 404 → 폴링)입니다. 순서를 맞출 필요가 없습니다.
- `[observability] enabled = false`(좌표 유출 방지, 대표 결정 2026-11-18)는 **그대로 둡니다.** 계측은 Cloudflare 대시보드의 DO 지표로 합니다.
- **동시 작업 주의(중요)**: 같은 inbox의 `20261120-1820-국내선-항공편-카드-조회.md`(FLT1120A01)가 **지금 production 배포를 승인받아** 처리될 수 있습니다. `wrangler deploy`는 **워커 전체**를 올리므로, 이 지시서의 코드가 그 전에 main에 있으면 `/rt/ws`와 migration `v3`도 **그 배포에 함께 살아납니다.** 그때는 ⑴ 그 배포가 이 지시서의 코드도 포함했다는 사실과 시각을 회신에 적고 ⑵ 배포 직후 키 없이 `GET /rt/ws`가 **401**로 답하는지(=`/rt/ws`가 살아 있다) 확인만 하십시오. 앱이 아직 소켓을 안 쓰므로 사용자에게 보이는 변화는 없습니다.
- 대표가 이 기능의 가동을 원치 않으면 **클래스를 지우지 말고**(migration은 되돌릴 수 없습니다) `wrangler.local.toml`에서 `REALTIME_ROOM` 바인딩만 빼십시오 — 라우트가 503, 발행은 무동작이 되어 앱은 폴링으로 그대로 돕니다.

## 9. APNs — 이미 있으니 새로 만들지 않습니다

- `queueCommand`가 이미 `notify(ctx, pushForCommand(command))`로 **침묵 푸시 `cmd`**를 보냅니다(`apns.js:74·90`, `store.js:536`). 이번에 만들 것이 없습니다.
- **`POST /plan`은 아무 푸시도 보내지 않습니다**(`store.js:56~62` 확인). 백그라운드에서 여행 계획 도착을 알리고 싶으면 그건 별도 결정·별도 지시입니다 — 이번에 **손대지 말고** 회신에 사실만 적으십시오.
- 앱이 백그라운드면 소켓을 닫으므로(4절①), 그때의 알림은 지금 있는 푸시가 맡습니다.

## 10. 시험

**서버**(`server/trip-relay/test/realtime.test.mjs`, `fakes.mjs`의 가짜 `SOCKETS`·가짜 시계 재사용, `npm test` 통과):

1. 업그레이드가 아닌 `GET /rt/ws` → 426. 키 없음·틀린 키 → **401**. AI 연결 키(비주인) → **401/403**(소켓 안 열림).
2. 업그레이드 → `hello` → `since` 이후 이벤트가 **id 오름차순**으로, 50건씩 `more`와 함께.
3. 이벤트 205건 → 오래된 5건 삭제, `since=1` → `resync`. `since > latest` → `resync`.
4. `POST /command`(AI 키) → 소켓이 `{type:"cmd"}` **1건** 받는다. `POST /plan` → `{type:"patch",entity:"plan"}`.
5. **주인 키**로 쓴 `POST /app` → 발행 **0건**(자기 화면 고리 방지).
6. `ping` → `pong`(auto response). 타이머·알람이 **없음**을 코드로 확인(`setInterval`·`setAlarm` grep 0).
7. hibernation 흉내: 연결을 끊었다 같은 id로 다시 붙으면 attachment가 복원되고 `since`로 밀린 것을 받는다.
8. 발행 실패(DO 던짐) → 명령 응답은 **201 그대로**(발행이 정본을 막지 않는다).
9. 주인 방에 6번째 연결 → 가장 오래된 것이 `bye 4408`.

**앱 단위 시험**(`TaptionPlanTests`, 가짜 소켓·가짜 시계):

1. `cmd` 1건 → 반영 1회. 같은 id 3번 → 반영 **1회**(기존 장부).
2. `patch(plan)` → 여행 화면만 갱신, 다른 화면 갱신 **0회**.
3. `.background` → 소켓 닫힘·요청 0건.
4. 토글 끔 → 소켓을 열지 않고 폴링만. 세그먼트 「끔」 → 폴링도 정지.
5. 끊김 3회 → 폴링 전환, 통화 중이면 1초·아니면 3초(RTA 값).
6. 커서 저장·복원, `resync`에서 0으로.
7. `hello.latest`를 이벤트 다 받기 전에 커서로 쓰지 않는다(이벤트 유실 없음).
8. `null`·`pong`·아주 긴 글자 같은 예상 밖 메시지 → 앱이 죽지 않고 무시.

**실기기**(기본 아이폰 11 Pro, 대표 체감은 아이폰 18 Pro Max — 구분해 적음):

1. 여행 화면을 열어 둔 채 AI가 항공편 구간을 보내고 **줄이 나타나기까지 초**를 5회. 비교: 소켓 끔(폴링 3초)·폴링 1초.
2. 백그라운드 1분 → 소켓 **0개**·요청 **0건**(중계 로그 대신 앱 계측 카운터).
3. 1시간 열어 둔 배터리 %·데이터 바이트(소켓 켬/끔).
4. 비행기 모드 30초 → 폴링 전환·한 줄 표시, 해제하면 소켓 재접속.
5. 통화 중(1초 폴링 모드) 소켓이 붙으면 **폴링이 멈추는지**(요청 수로 확인).
6. **대시보드 지표**(배포 뒤): Workers & Pages → Durable Objects → `RealtimeRoom`의 요청·duration. 첫날 값을 숫자로.

**회귀**(깨지면 안 되는 것): RTA1120A01의 폴링 3초·1초와 「끔」, 백그라운드 정지, 중복 반영 장부, `/command/result` 보고·큐 삭제, 여행 계획 카드, 말풍선 하루 한도, 설정 파일·백업 형식. 서버는 `npm test` 전체(기존 `share.test.mjs` 포함) 통과.

## 11. 문서·기록

- `test.md`: 요청 ID **RTA1120A02** — `## 남은 작업` 「AI·PCC」에 한 줄, `### 요청 상세`에 원인·해결·검증 기준. RTA1120A01이 아직 `test.md`에 없으면 **둘을 함께** 넣고, 설명에 「A01(폴링) → A02(소켓)」 관계를 한 줄로 적으십시오. `## 검증 기록`에 결과 절(실행 명령·측정값·대시보드 숫자).
- `AGENTS.md` 4절 **대표 결정**에 날짜와 함께: 「2026-11-20: 앱 전면 실시간 반영은 WebSocket(Durable Object Hibernation) 우선, 끊기면 폴링(RTA1120A01). 중계는 Workers Free 한도 안에서만 돌리고 유료 전환은 대표 승인. 백그라운드에서는 소켓을 닫는다.」 다른 결정은 건드리지 않습니다.
- `docs/AI_RELAY_PLAN.md`에 「실시간(WebSocket) 반영」 소절 하나(접속·이벤트·따라잡기·폴백), `docs/ACTIVITY_RELAY_API.md` 2절 경로 표에 `/rt/ws` 한 줄(업그레이드·헤더 인증·이벤트 모양). **기존 규격은 바꾸지 않습니다.**
- `PRIVACY.md`: 새로 모으는 개인정보 **없음**(좌표·기기 ID·본문을 싣지 않음)을 확인하고 회신에 한 줄. 바뀌는 게 없으면 문구 변경 없음.

## 12. 하지 말 것

- **`wrangler deploy` 실행, migration 적용**(대표 확인 전), `wrangler.local.toml`·`.wrangler/`를 커밋하는 것.
- 표준 WebSocket API(`ws.accept()`), `setInterval`·`setTimeout`·`setAlarm` 하트비트, 장시간 `await`(hibernation 차단 → 6절 요금 폭발).
- 이벤트에 **본문·금액·좌표·이름** 싣기, 기기 ID 원문 저장·전송, 토큰을 쿼리·로그·문서에 남기기.
- 폴링(RTA1120A01) 줄 삭제·약화 — 폴백이 이 설계의 안전판입니다.
- 이벤트마다 무거운 곁일(영수증 스캔·질문 올리기·규칙 동기화) 부르기.
- APNs 새로 만들기, `/plan` 푸시 추가(9절 — 별도 결정).
- 공지·시즌 팩·항공편 지시서와 겹치는 캐시·규격 새로 만들기(기존 재사용).
- 동결 파일 수정: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`.
- `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리기, `docs/architecture-baseline.json` 고치기.
- 다른 세션의 미커밋 변경(`TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`) 커밋 포함. 경로를 지정해 이번에 만진 파일만.
- `pickle-bridge/inbox/` 밖(`done/`)으로 이 문서 옮기기 — 회신은 이 문서에 적습니다.
- 측정 없이 「실시간으로 된다」고 보고하기, 돌리지 않은 시험을 통과로 적기.

## 13. 회신에 담을 것 (`pickle-bridge/README.md` 4절 형식)

- 처리: 완료 / 일부 / 막힘 · 요청 ID(RTA1120A02) · 시작·끝 · 커밋 해시
- **만든 것**: 클래스·라우트·발행 자리(파일:줄), migration 태그, 앱 쪽 파일
- **서버 시험**: `npm test` 실행 수·실패·건너뜀(기존 `share.test.mjs` 포함), 새 시험 항목별 결과
- **dry-run 출력**: `REALTIME_ROOM`·`v3-realtime-room` 확인(실제 deploy는 **하지 않았음**을 명시)
- **실기기 측정**: 반영까지 걸린 초(소켓/폴링 3초/폴링 1초 각각), 배터리·데이터, 백그라운드 요청 0건 확인
- **요금**: 6절 계산을 실제 값으로 대체(대시보드는 배포 뒤라 「배포 뒤 확인 필요」로)
- **`POST /plan`에 푸시가 없다는 사실**, 서버 배포가 남았다는 사실
- 바꾼 파일, 번역 대기 문구 수
- 막혔으면 문서를 옮기지 말고 `status: blocked` + 객관식 질문(추천을 첫째에)

## 참고

- 이 지시서 2절의 파일:줄은 2026-11-20 18:1x `fdbd12e6`에서 확인한 것입니다. 착수 때 `rg -n`으로 다시 보고, 달라졌으면 회신에 적으십시오.
- 바로 위 지시서: `pickle-bridge/inbox/20261120-1805-realtime-screen-sync.md`(RTA1120A01 — 이 지시서가 딛고 서는 바닥).
- 같은 모양의 선례: `server/trip-relay/src/share.js`(`ShareRoom` Hibernation 소켓 전체), `Packages/TaptionTripShare/Sources/TaptionTripShare/ShareTransport.swift`·`ShareSocketChannel.swift`·`ShareSessionTypes.swift`.
- 규격: `docs/ACTIVITY_RELAY_API.md`(경로·명령), `docs/AI_RELAY_PLAN.md`(AI 파이프라인), `server/trip-relay/README.md`(배포·비밀값·D1).
- 규칙: `AGENTS.md` 2·4·5·6·7·8·9·12절, 브리지 형식: `pickle-bridge/README.md`.

## 점검 회신 (비야, 2026-11-20 18:51)

- 보안: 토큰을 쿼리에 두지 않고 헤더로만, 기기 ID를 저장·로그하지 않고, 이벤트에 본문·금액·이름·좌표를 싣지 않고, `POST /event`(발행)는 DO 바인딩으로만 닿는 문으로 둔 설계는 그대로 유지했습니다. 방 이름을 주인 키 해시(`ctx.master`)로 쓰는 것도 그대로입니다(원문 아님).
- 비업그레이드 `GET /rt/ws` 426·키 없음 401·AI 키 401/403·연결 상한 5를 시험에 넣어 둔 것도 그대로이며, 배포 뒤 `GET /rt/ws` **401 확인**을 회신 항목으로 넣었습니다.
- 요금(과금): hibernation 강제·타이머 금지가 요금 조건이라는 서술은 Cloudflare 문서와 어긋나지 않고, 한도 초과 시 폴링 폴백이 안전판이라는 구조도 그대로입니다.
- 2절의 파일:줄은 18:4x `origin/main`에서 **그대로 맞았습니다** — `share.js` 148·695~706·708~735·736~750·757·773~783, `wrangler.toml` 73~81, `state.js` 781, `store.js` 56·78·127·194·363·512·536, `apns.js` 74·90, `index.js` 366(ROUTES)·559~566(authorized), `fakes.mjs` 121~125.
- 처리 순서를 머리에 넣고 FLT 배포와의 경합을 한 줄 더했습니다. 고치지 않은 것: 라우트 모양(`/rt/ws`)·이벤트 규격·요금 계산·대안 판단(새 `RealtimeRoom` 클래스)은 비야 제안이라 그대로 두었습니다.
- 근거(Cloudflare): `developers.cloudflare.com/durable-objects/platform/pricing/`(플랜·한도·WebSocket 과금·SQLite 저장 한도), `developers.cloudflare.com/durable-objects/best-practices/websockets/`(Hibernation API·`acceptWebSocket`·`webSocketClose`).
