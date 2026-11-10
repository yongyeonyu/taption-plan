# AI 비서 ↔ Taption Plan 하루 기록·명령 연동 규격 (AIR1110A01·TRP1110A07·AIR1110A02·SEC1110A02·AIR1110A03·REV1110A06)

여행 계획 중계(`docs/TRIP_RELAY_API.md`)와 같은 서버·같은 연동 키로, AI 비서가 사용자의 하루 기록을 읽고(앱 → 서버 → AI) 메모·일정·기록 수정을 보낸다(AI → 서버 → 앱). 서버 코드는 `server/trip-relay/src/`(`index.js` 경로표, `keys.js` 등록·PIN·연결 키, `state.js` 주인마다의 Durable Object, `store.js` 저장, `oauth.js` OAuth 2.1, `mcp.js` MCP, `openapi.js`), 앱 코드는 `TaptionPlan/UI/Assistant*.swift`다.

## 1. 주소·인증·설정

| 항목 | 값 |
|---|---|
| 주소 | `https://trip.bokkiyaw.com` |
| 인증 | 모든 요청에 `Authorization: Bearer <키>`, 본문이 있으면 `Content-Type: application/json`. 키는 앱만 가진 주인 키(master, 43자, `POST /register`로 등록해야 받는다), AI에 주는 읽기·쓰기 연결 키(43자), OAuth 토큰(64자, 14장), 지도 검색 전용 설치 키(43자)가 있다(7·12장). 등록되지 않은 키는 모든 경로에서 `401 {"error":"unregistered"}` |
| 연결 | 앱 메인 메뉴 → 연결 → 「AI 연결」(피클·ChatGPT·Claude·Gemini·기타). 연결 키 만들기와 OAuth 연결 코드는 앱 비밀번호로 승인한다(13장, 서버에는 앱 비밀번호에서 만든 다른 6자리가 간다) |
| 기록 공유 | 「보내지 않음」·「하루 요약」(기본)·「머문 곳 이름과 시각」. 기기에만 저장. 끄면 앱이 `DELETE /activity`를 한 번 부른다 |
| 서버 보관 기간 | 1일·7일(기본)·30일. 마지막으로 올린 때부터 센다. 줄이면 앱이 `DELETE /activity` 뒤 새 기간으로 다시 올린다 |

서버는 키의 SHA-256 해시만 이름으로 쓰고, 값은 사용자 DEK로 암호화해 둔다(6장). 한도는 15장: IP마다 모든 요청 1분 120번(`REQUEST_LIMIT`)과 본문 있는 쓰기 1분 20번(`POST_LIMIT`), 주인 키 1분 120번·하루 2,000번, 연결들은 따로 함께 1분 120번·하루 2,000번이고 연결 하나는 1분 60번·하루 1,000번(Durable Object). 명령 검사의 기준은 서버(`validate.js`)이고 앱은 4.1·4.2장을 그대로 따른다. 본문은 스트림으로 64KB까지 읽고 넘으면 그 자리에서 `413`.

## 2. 경로

범위: 주인(master)은 모두, 읽기(read) 키는 「AI·읽기」, 쓰기(write) 키는 읽기 + 「AI·쓰기」. 범위 밖은 `403`.

| 요청 | 누가(범위) | 본문·질의 | 응답 |
|---|---|---|---|
| `POST /activity` | 앱 | `{"format":"bokki-activity","version":1,"retentionDays":1\|7\|30,"days":[하루 1~7개]}` | `201` `{"ok":true,"dates":[…],"expiresInSeconds":…,"written":n}`(`written` = 실제로 다시 쓴 날 수, 같은 내용은 0), `422` 형식·보관 기간·날 수가 틀림, `429` `daily_write_limit`·`write_budget_exhausted`, `503` `{"error":"migrating","retryAfter":60}` 예전 자료를 옮기는 중(16장) |
| `GET /activity?date=YYYY-MM-DD` | AI·읽기 | 없음 | `200` 그날 하루, `204` 없음, `400` 날짜 형식 틀림 |
| `GET /activity` | AI·읽기 | 없음 | `200` `{"days":[…]}` 있는 날 중 최근 7일(최신 먼저), `204` 없음 |
| `DELETE /activity` | 앱 | 없음 | `204` 이 키의 모든 날을 지운다 |
| `GET /activity/summary?range=week\|month[&end=YYYY-MM-DD]` | AI·읽기 | 없음 | `200` 묶음(8장), `204` 그 기간에 날 없음, `400` 기간·날짜 틀림 |
| `POST /command` | AI·쓰기 | 아래 명령 하나 | `201` `{"ok":true,"id":"…","queued":n,"remainingToday":n,"expiresInSeconds":604800}`, `422` 형식 틀림(`{"error":"not_command","reason"?}`, `reason`은 `bad_id` 또는 말풍선 이유), `409` `{"error":"id_conflict"}` 다른 연결이 넣어 둔 같은 `id`, `429` 24시간 30개 초과(`{"error":"daily_command_limit","retryAfterSeconds"}`, `Retry-After` 헤더) |
| `GET /command` | 앱 | 없음 | `200` `{"commands":[…]}`, `204` 없음 |
| `DELETE /command?ids=a,b` | 앱 | `ids`가 없으면 전부 | `204` |
| `POST /command/result` | 앱 | `{"results":[{"id","status":"applied"\|"rejected","reason"?}]}` | `201` |
| `GET /command/result` | AI·읽기 | 없음 | `200` `{"results":[{"id","status","reason"?,"at"}]}`, `204` 없음 |
| `POST /polish` | 앱 | `{"format":"bokki-polish","version":1,"memos":[{"id","text","date"?}]}` 1~20개, 글 1~1,000자, id 겹침 없음. 목록 전체를 바꿔 쓴다(MEM1110A02) | `201` `{"ok":true,"count":n,"expiresInSeconds":604800}`, `422` `not_polish_list` |
| `GET /polish` | AI·읽기 | 없음 | `200` 위 목록(모르는 칸은 버림), `204` 없음. AI는 다듬은 글을 `updateMemo`로 보낸다. MCP `get_polish_requests` |
| `DELETE /polish` | 앱 | 없음 | `204`. 앱은 목록이 비면 지운다 |
| `POST /setup` | 앱 | `{"text":"<연결 안내, 8,000자까지>"}` (SET1110A01) | `201` `{"ok":true,"code":"<10자>","url":"https://…/s/<코드>","expiresInSeconds":600}`, `422` `not_setup`, `429` `daily_setup_limit`(하루 30개) |
| `GET /s/<코드>` | 누구나(코드를 아는 쪽) | 없음 | `200` 안내 글(`text/plain`, `no-store`), `404` 없음·끝남. 코드에서 HKDF로 만든 키로 잠그고 이름은 코드의 해시라 서버에 코드·키가 그대로 남지 않는다. 10분 또는 3번 읽으면 사라진다(링크 미리보기가 먼저 열어도 AI가 읽게) |
| `GET /plan` · `POST /plan` | AI·읽기 · AI·쓰기 | 여행 JSON(`docs/TRIP_RELAY_API.md`) | 그대로. `DELETE /plan`은 앱만 |
| `POST /register` | 새 키 자신(Authorization) | `{}` · `{"purpose":"search"}` (`pinVerifier`는 무시) | 12장 |
| `POST /keys` · `GET /keys` · `DELETE /keys[?id=]` | 앱 | 7장(만들 때 `"pin"` 필요) | 7장 |
| `POST /pin` · `GET /pin` · `POST /pin/reset` | 앱(주인 키만) | 13장 | 13장 |
| `POST /oauth/code` | 앱 | 없음 | 14장 |
| `GET /kakao/keyword?query=…` | 검색 키·앱 | 카카오 검색 중계 | 키마다 하루 500번(15장) |
| `/.well-known/oauth-*`, `/oauth/register`·`/oauth/authorize`·`/oauth/token` | 누구나·AI 앱 | OAuth 2.1 | 14장 |
| `POST /mcp` | AI·읽기(도구마다 범위) | JSON-RPC 2.0 | 9장 |
| `GET /openapi.json` | 누구나(인증 없음) | 없음 | OpenAPI 3.1(10장) |

- 하루는 `act:<주인 해시>:<HMAC(날짜) 32 hex>`에 따로 저장되고(KV 이름에 날짜가 보이지 않는다, 6.3) TTL은 `retentionDays × 86400`초다. 읽어도 지우지 않는다. 어떤 날이 있는지는 Durable Object가 날짜를 잠근 채 가진다(KV `list`를 쓰지 않는다).
- 하루마다 앱의 공유 수준에 따라 `goals: [{id,title,start,end}]`, `trips: [{tripId, items:[{stopId,itemId,title,order,start,end,status}]}]`, `sleep: [{recordId,start,end,minutes,source}]`가 붙는다. 서버는 하루 JSON을 해석하지 않고 그대로 잠가 두고 `GET /activity`와 MCP `get_activity`로 그대로 준다. (선택) 업로드 최상위의 `goals`·`trips`·`placeBook`도 받아 `ext:<주인>`에 같은 보관 기간으로 두고 날짜 없는 `GET /activity`에 붙인다. 보낸 칸만 바꾸고 `null`이면 지운다. 앱은 지금 쓰지 않는다(`placeBook`은 앱에 없다).
- 명령 큐는 Durable Object에(명령마다 DEK로 잠금, 최근 50개, 7일 지나면 버림), 결과(`cmdres:<해시>`)는 KV에 최근 50개·TTL 7일. 같은 `id`를 같은 연결이 다시 보내면 새 값으로 바꾸고, 다른 연결이 넣어 둔 `id`면 `409 id_conflict`다. `id`는 영문·숫자·`_`·`.`·`:`·`-` 1~100자(`^[\w.:-]{1,100}$`, 공백·쉼표·한글 없음). `DELETE /command?ids=`와 `POST /command/result`는 예전에 받은 느슨한 id(공백 포함)도 받는다. `GET /command`의 명령마다 `keyId`(보낸 연결의 `id` = 키 해시 앞 8자 hex, OAuth는 연결 id, 주인 키로 보낸 것은 `"master"`, 예전 큐에서 옮긴 것은 `null`)와 `source`(`rest`·`mcp`·`oauth`·`legacy`)가 붙는다. 앱은 `keyId`가 살아 있는 연결이 아니면(그리고 `legacy`가 아니면) 반영하지 않고, 「AI가 한 일」에 연결 이름을 보인다.
- 명령은 주인 이름 하나에 24시간(이동 창) 30개까지 받는다. Durable Object가 한 줄로 세므로 동시에 보내도 넘지 않는다. 앱이 큐를 비워도 수는 줄지 않는다.
- 연결 키·OAuth 연결을 끊으면 그 연결이 보낸, 아직 처리하지 않은 명령도 큐에서 지운다.
- 명령은 동작마다 정한 칸만 남기고 나머지는 버린다(`keyId`·`source`·`receivedAt`을 보내도 서버 값으로 바뀐다).
- 공통 오류: `400` JSON 아님, `401` 키 없음·형식 틀림·만료·폐기(`unauthorized`) 또는 등록 안 됨(`unregistered`), `403` 범위 밖, `405` 다른 메서드, `413` 64KB 초과, `429` 속도 제한(`rate_limited`·`daily_request_limit`)·KV 쓰기 예산(`daily_write_limit` 주인마다 하루 600, `write_budget_exhausted` 서버 전체) — 모두 `retryAfter` 초와 `Retry-After`, `503` `storage_unavailable`(저장소가 쓰기를 거절, 잠시 뒤 다시).

## 3. 하루 기록(`days[]`)

| 칸 | 「하루 요약」 | 「머문 곳 이름과 시각」 | 설명 |
|---|---|---|---|
| `date`·`timeZone`·`updatedAt` | ○ | ○ | 기기 시간대 기준 날짜, IANA 시간대, 올린 시각 |
| `summary` | ○ | ○ | `categories[{id,title,minutes}]`(미확인 제외, 긴 순), `recordedMinutes`, `steps`(있을 때), `plansScheduled`, `plansCompleted` |
| `records` | ○ | ○ | `{id,start,end,title,category{id,title},source}` 시간순, 최대 200개. `id`는 앱 기록 id(UUID)로 `updateActivity`에 쓴다. `source`는 `auto`(센서·건강 자동) 또는 `user`(직접 입력·사용자 교정) |
| `memos` | ○ | ○ | `{id,time?,text}` 시간순, 최대 50개(글 1,000자까지). 시각 없는 메모는 `time`이 없다 |
| `visits` | ✕ | ○ | `{place,start,end,minutes}` 5분 이상 머문 곳, 지하철·기차로 지나간 자리는 뺀다 |
| `moves` | ✕ | ○ | `{from,to,mode,start,end,minutes}` 이동 구간. `from`·`to`는 앞뒤 머문 곳 이름 또는 `null`, `mode`는 `walk`·`subway`·`bus`·`car`·`train`·`flight`·`other` |

시각(`start`·`end`)은 `2026-11-10T09:00+09:00`처럼 분까지, 기기 시간대 오프셋을 붙인다.

장소 이름: 사용자가 등록한 장소면 그 이름, 아니면 머문 곳의 이름·건물 이름이 주소처럼 보이지 않을 때만 그 이름, 그 밖에는 「머문 곳」(영어 화면은 `Place`).

**보내지 않는 것**: 좌표(위도·경도), 경로·이동 선, 주소, 센서 원본, 사진·음성 첨부, 메모의 지도 위치. 「하루 요약」에는 장소 이름이 하나도 들어가지 않는다.

앱은 앱이 켜질 때·백그라운드로 갈 때 오늘과 지난 6일(보관 기간이 1일이면 오늘만) 중 바뀐 날을, 기록이 저장된 뒤에는 5분에 한 번 오늘만 올린다. 날마다 `updatedAt`을 뺀 내용의 해시를 기기에 두어 같은 내용은 다시 올리지 않는다. 서버도 같은 일을 한다(REV1110A06): 올린 하루가 저장된 것과 `updatedAt`만 다르고 만료까지 보관 기간의 3/4 넘게 남았으면 KV에 다시 쓰지 않는다(응답 `written`에서 빠짐). 그래서 하루는 마지막으로 올린 때부터 보관 기간의 3/4 이상 남는다. 날짜가 다른 하루는 주인마다 62개까지 두고, 넘으면 먼저 만료되는 날부터 지운다. 실패해도 화면에는 알리지 않고 진단 기록만 남긴다.

### 「하루 요약」 예

```json
{
  "date": "2026-11-10",
  "timeZone": "Asia/Seoul",
  "updatedAt": "2026-11-10T21:05+09:00",
  "summary": {
    "categories": [{ "id": "work", "title": "업무", "minutes": 540 }, { "id": "movement", "title": "이동", "minutes": 30 }],
    "recordedMinutes": 570,
    "steps": 6000,
    "plansScheduled": 2,
    "plansCompleted": 1
  },
  "records": [
    { "id": "6F1C2D1E-0B7A-4C55-9D3E-1A2B3C4D5E6F", "start": "2026-11-10T08:30+09:00", "end": "2026-11-10T09:00+09:00", "title": "걷기", "category": { "id": "movement", "title": "이동" }, "source": "auto" },
    { "id": "0D9E8F7A-6B5C-4D3E-2F1A-0B9C8D7E6F5A", "start": "2026-11-10T09:00+09:00", "end": "2026-11-10T18:00+09:00", "title": "업무", "category": { "id": "work", "title": "업무" }, "source": "auto" }
  ],
  "memos": [{ "id": "A1B2C3D4-E5F6-4789-9ABC-DEF012345678", "time": "12:00", "text": "점심 약속" }]
}
```

### 「머문 곳 이름과 시각」 예 (위 내용에 더해)

```json
{
  "visits": [
    { "place": "우리 집", "start": "2026-11-10T00:00+09:00", "end": "2026-11-10T08:30+09:00", "minutes": 510 },
    { "place": "머문 곳", "start": "2026-11-10T09:00+09:00", "end": "2026-11-10T18:00+09:00", "minutes": 540 },
    { "place": "블루보틀", "start": "2026-11-10T18:20+09:00", "end": "2026-11-10T19:30+09:00", "minutes": 70 }
  ],
  "moves": [
    { "from": "우리 집", "to": "머문 곳", "mode": "subway", "start": "2026-11-10T08:30+09:00", "end": "2026-11-10T09:00+09:00", "minutes": 30 },
    { "from": "머문 곳", "to": "블루보틀", "mode": "walk", "start": "2026-11-10T18:00+09:00", "end": "2026-11-10T18:20+09:00", "minutes": 20 }
  ]
}
```

## 4. 명령(`POST /command`)

공통: `{"format":"bokki-command","version":1,"id":"<고유 id, ^[\w.:-]{1,100}$>","action":"…", …}`. 앱은 다음에 열릴 때(포그라운드로 올 때)와 **백그라운드 새로 고침 때에도** 모든 명령을 순서대로 **묻지 않고 반영**하고(대표 결정; 백그라운드에서는 알림을 띄우지 않고 「AI가 한 일」에만 남는다), 「AI 비서 요청을 반영했어요: 메모 1개 · 기록 수정 1개」 같은 알림을 잠깐 띄운다. 처리한 명령은 큐에서 지우고 결과를 `/command/result`에 남긴 뒤 하루 기록을 다시 올린다. 기기는 처리한 id 최근 200개를 기억해 같은 명령을 두 번 반영하지 않는다.

| action | 칸 | 앱이 하는 일 |
|---|---|---|
| `addMemo` | `text`(1~1000자), `date`(`YYYY-MM-DD`, 없으면 오늘), `time`(`HH:mm`, 없으면 오늘은 지금·다른 날은 정오) | 그 시각의 메모로 넣는다 |
| `addSchedule` | `title`(1~200자), `start`(ISO, 오프셋 포함), `end`(선택, `start`보다 뒤), `note`(선택, 1000자까지) | 「일반 활동」 분류 계획으로 넣는다. `end`가 없으면 1시간. `note`는 그 계획의 메모가 된다 |
| `updateActivity` | `date`, `recordId` 또는 `startTime`(`HH:mm`) 중 하나 이상, `title`·`categoryId` 중 하나 이상 | `recordId`가 있으면 그 기록, 없으면 그날 `startTime`을 덮는 기록(여럿이면 늦게 시작한 것)을 고른다. 사용자 교정(교정표)으로만 고쳐 자동 원본·근거는 남고 되돌릴 수 있다 |
| `hideRecord` | `date`, `recordId` 또는 `startTime` 중 하나 이상 | 자동 기록을 사용자 교정으로 숨긴다(CLN1110A01) |
| `mergeRecords` | `date`, `recordIds`(2~20개, 서로 다른 id), `title`(선택, 100자), `categoryId`(선택) | 이어진 기록들을 사용자 교정 블록 하나로 합친다 |
| `updateRecordTime` | `date`, `recordId`, `start`·`end`(`HH:mm`) 중 하나 이상, 둘 다면 서로 달라야 함 | 기록의 시작·끝을 교정한다 |
| `updateSchedule` | 대상 `planId` 또는 (`date`, `startTime`); 바꿀 칸 `title`(200자)·`start`·`end`·`note`(1000자, 빈 글 가능) 중 하나 이상 | `start`·`end`는 ISO(오프셋 포함) 또는 `HH:mm`. 둘 다 ISO면 `end`가 뒤 |
| `deleteSchedule` | `planId` 또는 (`date`, `startTime`) | 계획을 지운다(되돌릴 수 있음) |
| `updateMemo` | `memoId`, `text`(1~1000자) | 메모 글을 바꾼다 |
| `deleteMemo` | `memoId` | 메모를 지운다(되돌릴 수 있음) |
| `addGoal` (AIR1110A03) | `title`(1~200자), `start`(`YYYY-MM-DD`), `end`(선택, `start` 이후), `categoryId`(선택) | 목표(상위 계획)를 만든다 |
| `updateGoal` | `goalId`(또는 `planId`; 둘 다 보내면 둘 다 1~100자 id여야 한다); `title`·`start`·`end`·`categoryId` 중 하나 이상(`categoryId`만 바꿔도 됨) | 목표를 고친다 |
| `deleteGoal` | `goalId`(또는 `planId`) | 목표를 지운다(되돌릴 수 있음) |
| `addTripStop` | `title`(1~200자), `date`(`YYYY-MM-DD`), `latitude`+`longitude`(선택, 둘 함께; `lat`+`lng`도 받고, 두 쌍을 다 보내면 둘 다 맞아야 함), `status`(선택, `booked`·`planned`·`tentative`), `tripId`(선택) | 여행 일정(장소)을 더한다. 좌표가 없어도 된다 |
| `updateTripStop` | `stopId`; `title`·`date`·`order`(정수 0~999)·`status` 중 하나 이상 | 여행 일정을 고친다 |
| `deleteTripStop` | `stopId` | 여행 일정을 뺀다(되돌릴 수 있음) |
| `setTripItemStatus` | `tripId`, `itemId`, `status` | 시간 일정의 예약·계획·미정을 바꾼다 |
| `updateSleep` | `recordId`(하루의 `sleep[].recordId`), `start`·`end`(ISO 오프셋 포함 또는 `HH:mm`) 중 하나 이상, 둘 다 ISO면 끝이 뒤 | 수면 기록의 시작·끝을 사용자 교정으로 고친다 |
| `setBubble` (BUB1110A01·A02) | `date`(`YYYY-MM-DD`), `kind`(`routine` 기본·`event`), `start`·`end`(`HH:mm`, 같은 날 `end` > `start`; `event`는 둘 다 없으면 그날 하루), `text` | **보이기만 한다**: 그 시각에 화랑이 말풍선을 띄운다. 기록·계획·메모를 만들거나 바꾸거나 지우지 않는다. 앱은 받은 말풍선을 기기와 앱 DB(`assistant-bubble`, 월별 백업 포함)에 남기고, 재생·사이드바 핸들로 그 시각을 보면 다시 보인다. 보이는 순서는 그날의 `event` → 그 시각의 `routine` → 앱 내장 기본 문구(대분류별). `event`는 그날이 지나면 앱이 지운다. 글 규칙은 아래. AI 쪽 사용법은 `docs/AI_ASSISTANT_GUIDE.md` |
| `setLanguage` | `language`: `automatic`·`korean`·`english`·`ja`·`zh-Hans`·`zh-Hant`·`de`·`fr`·`it`·`es`·`pt-BR`·`vi`·`id`·`th`·`hi` | 앱 언어 |
| `setTheme` | `theme`: `classic`·`navy`·`purple`·`brown`·`ink` | 화면 테마 |
| `setMapStyle` | `mapStyle`: `standard`·`hybrid`·`mapLibreNight`·`mapLibreContrast`·`mapLibreCasual`·`mapLibreRPG`·`mapLibreInk` | 지도 모양 |
| `setDisplayOption` | `option`: `mapPhotos`(지도에 사진)·`mapRoutes`(지도에 경로 선)·`mapFootprints`(지도에 발자국), `enabled`(true/false) | 지도 표시 켜고 끄기. 이 셋만 |

### 4.1 칸마다의 한도 (서버 `validate.js`가 기준, 앱은 이 표를 따른다)

길이는 UTF-16 코드 단위(JavaScript `length`)로 센다. 「글」은 앞뒤 공백을 뺀 뒤 한 글자 이상이어야 한다. 표에 없는 칸은 서버가 큐에 넣기 전에 버린다. 보낸 칸은 모두 검사하고 하나라도 틀리면 `422 not_command`다.

| 칸 | 모양·한도 | 쓰는 동작 |
|---|---|---|
| `id` | `^[\w.:-]{1,100}$` (영문·숫자·`_`·`.`·`:`·`-`) | 모든 동작(필수). MCP는 없으면 `mcp-<UUID>` |
| `text` | 글 1~1000자 | `addMemo`·`updateMemo` |
| `text` (말풍선) | 4.2장 | `setBubble` |
| `title` | 글 1~200자 | `addSchedule`·`updateSchedule`·`addGoal`·`updateGoal`·`addTripStop`·`updateTripStop` |
| `title` | 글 1~100자 | `updateActivity`·`mergeRecords` |
| `note` | 0~1000자(빈 글 가능) | `addSchedule`·`updateSchedule` |
| `recordId`·`planId`·`memoId`·`goalId`·`tripId`·`itemId`·`stopId`·`categoryId` | 글 1~100자 | 해당 동작 |
| `recordIds` | 서로 다른 id 2~20개(각 1~100자) | `mergeRecords` |
| `date` | `YYYY-MM-DD`(있는 날짜) | `addMemo`·`updateActivity`·`hideRecord`·`mergeRecords`·`updateRecordTime`·`updateSchedule`·`deleteSchedule`·`addTripStop`·`updateTripStop`·`setBubble` |
| `time`·`startTime` | `HH:mm`(00:00~23:59) | `addMemo`(`time`), `updateActivity`·`hideRecord`·`updateSchedule`·`deleteSchedule`(`startTime`) |
| `start`·`end` (ISO) | `YYYY-MM-DDTHH:mm[:ss]` + `Z` 또는 `±HH:MM` | `addSchedule`(필수 `start`, `end`는 뒤) |
| `start`·`end` (`HH:mm`) | `HH:mm` | `updateRecordTime`(하나 이상, 둘이 같으면 안 됨), `setBubble`(둘 다, 같은 날 `end` > `start`) |
| `start`·`end` (둘 중 하나) | ISO 또는 `HH:mm` | `updateSchedule`, `updateSleep`(하나 이상, 둘이 같으면 안 되고 둘 다 ISO면 `end`가 뒤) |
| `start`·`end` (날짜) | `YYYY-MM-DD`, `end` ≥ `start` | `addGoal`(필수 `start`)·`updateGoal` |
| `latitude`·`longitude` (`lat`·`lng`) | 수 -90~90 · -180~180, 둘 함께. **선택** | `addTripStop` |
| `order` | 정수 0~999 | `updateTripStop` |
| `status` | `booked`·`planned`·`tentative` | `addTripStop`·`updateTripStop`·`setTripItemStatus`(필수) |
| `language`·`theme`·`mapStyle`·`option` | 위 표의 값 중 하나 | 설정 동작 |
| `enabled` | `true`·`false` | `setDisplayOption` |

대상 고르기: `updateActivity`·`hideRecord`는 `date` + (`recordId` 또는 `startTime`), `updateSchedule`·`deleteSchedule`는 `planId` 또는 (`date` + `startTime`), `updateGoal`·`deleteGoal`은 `goalId` 또는 `planId`. 「하나 이상」인 바꿀 칸이 하나도 없으면 `422`다.

### 4.2 말풍선 글 문법 (`setBubble.text`, REV1110A06)

허용하는 것만 받는 문법 하나다. 서버(`validate.js` `bubbleText`)와 앱이 **같은 규칙**으로 검사하고, 서버는 다듬은 글(주소는 정규화한 것)을 큐에 넣는다. 앱은 받은 글을 같은 문법으로 다시 검사한다(서버를 믿지 않는다). 글자 수는 **유니코드 코드 포인트**로 센다(Swift `unicodeScalars.count`, JavaScript `[...text].length`).

차례대로:

1. **지우기**: 유니코드 일반 범주 Cc(제어)·Cf(서식: 방향 바꿈 U+202A~202E·U+2066~2069, 폭 없는 글자 U+200B~200D, U+FEFF 등)·Zl·Zp 글자를 모두 지운다. 그다음 앞뒤 공백을 자른다. 빈 글이면 `text_required`.
2. **역슬래시**: `\`가 하나라도 있으면 `bad_character`.
3. **링크 찾기**: 왼쪽부터 겹치지 않게 아래 둘 중 하나를 찾는다(scheme `https`는 대소문자 무관).
   - 마크다운: `[이름](주소)` — 이름은 `[` `]` `<` `>` `\`가 없는 글, 주소는 `https://` + 주소 글자 1개 이상이고 괄호 안 전체여야 한다.
   - 맨 주소: `https://` + 주소 글자 1개 이상. 바로 앞 글자가 `A-Z a-z 0-9 + . -`이면 맨 주소로 보지 않는다. 찾은 뒤 끝의 `. , ; : ! ?`는 주소에서 떼어 글로 돌려준다.
   - 주소 글자: `A-Z a-z 0-9 - . _ ~ : / ? # @ ! $ & * + , ; = %` 뿐이다. 공백·괄호 `( )`·`[ ]`·`< >`·따옴표·역슬래시·한글은 주소에 쓸 수 없다(필요하면 `%XX`로 적는다).
4. **주소 검사**(틀리면 `bad_url`): `https://` 뒤 첫 `/` `?` `#` 전까지가 authority다.
   - authority = 호스트 또는 `호스트:포트`(포트는 숫자 1~5자리). `@`(userinfo)가 있으면 거절.
   - 호스트(소문자로 바꿔 본다): `^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\.[a-z]{2,}$`, 253자 이하, 라벨 63자 이하, `xn--`로 시작하는 라벨(퓨니코드) 없음. 그래서 IP 주소·`localhost`·한글 도메인은 거절이다.
   - `%` 뒤에는 16진수 두 자리가 와야 한다.
   - WHATWG URL로 읽어 scheme이 `https`, 호스트가 위 호스트와 같아야 한다.
   - 저장하는 주소는 정규화한 `url.href`다(scheme·호스트 소문자, 기본 포트 `:443` 제거, 빈 경로는 `/`, `.`·`..` 경로 정리).
5. **이름 검사**(틀리면 `bad_link_label`): 공백만이 아니고 1~20자, 그리고 주소처럼 보이지 않아야 한다 — `://` 포함, `www.` 포함(대소문자 무관), 또는 「글자·숫자 + 점(`.` `．` `。` `｡`) + 영문 2자 이상」(예: `apple.com`, `애플.com`)이면 거절.
6. **남은 글 검사**: 보이는 글 = 링크 밖의 글 + 마크다운 링크의 이름(맨 주소는 빼고 이어 붙임).
   - 다른 scheme(`url_scheme_not_allowed`): `영문자로 시작하는 [A-Za-z0-9+.-]* + ":"` 바로 뒤에 공백이 아닌 글자가 오고, 그 낱말 앞이 `A-Z a-z 0-9 + . -`가 아닌 것. 예: `http://…`, `tel:010`, `mailto:a@b.co`, `javascript:…`, `kakaotalk://`, `taptionplan:x`, `ETA:15`. 그 낱말이 `https`면(읽지 못한 https 주소) `bad_url`. `Note: 메모`(뒤가 공백), `12:30`(숫자로 시작), `시간:3시`(한글)는 괜찮다.
   - `[` `]` `<` `>`가 남아 있으면 `bad_character`.
7. **수 세기**: 링크(마크다운 + 맨 주소) 3개까지(`too_many_links`). 보이는 글은 앞뒤 공백을 빼고 1자 이상(`text_required`) 80자 이하, 정규화한 전체 글은 300자 이하(`text_too_long`).

정규화한 글을 같은 문법에 다시 넣으면 같은 글이 나온다. 맨 주소 뒤에는 공백을 두는 것이 안전하다(한글을 붙여 쓰면 주소 글자가 아니라서 거기서 주소가 끝난다).

| 보낸 글 | 결과 |
|---|---|
| `[예약](HTTPS://Example.com) 확인` | 저장: `[예약](https://example.com/) 확인` |
| `봐 https://example.com/a. 그리고` | 그대로(끝의 `.`은 글) |
| `[apple.com](https://evil.example)` | `bad_link_label` |
| `[a [b] c](calshow:0)` · `<taptionplan:reset> hi` | `url_scheme_not_allowed` |
| `봐 https://evil.example\@trusted.example` | `bad_character` |
| `봐 https://user@example.com/` · `https://192.0.2.1/` · `https://xn--….kr/` | `bad_url` |

거절은 `422 {"error":"not_command","reason":…}`로 `reason`은 `text_required`·`text_too_long`·`too_many_links`·`bad_link_label`·`bad_url`·`bad_character`·`url_scheme_not_allowed`·`end_before_start`·`bad_time`·`bad_id`. 말풍선은 주인마다 24시간 48개로 따로 세고(명령 30개 한도에 들지 않음, 넘으면 `429 daily_bubble_limit`), 큐도 따로 48개라 다른 명령을 밀어내지 않는다. 다른 명령처럼 `keyId`·`source`가 붙는다.

**AI가 할 수 없는 것(앱에서만)**: 전체 기록 지우기, 백업·복원, 연결 키·PIN·주인 키 바꾸기, 연결 만들기·끊기, 권한(위치·건강·알림·날씨처럼 데이터가 나가는 것), 공유 수준·보관 기간, 구매, 장소 도감 요청 보내기(`addPlaceRequest`, 메일)와 방문 표시(`markPlaceVisited`). 이런 동작은 서버에 없어 `422`다. 

새 동작도 모두 묻지 않고 사용자 편집·교정으로 반영되며 되돌릴 수 있다. 센서 원본과 자동 기록 자체는 지우지 않는다. 앱은 동작마다 켜고 끌 수 있고(기본 모두 켬), 한 번에 기존 기록·계획·메모 20개 넘게 바뀌면 아무것도 반영하지 않고 확인 화면을 띄운다. `id`는 `GET /activity`의 `records[].id`·`memos[].id`·`plans[].id`를 쓴다.

거절 이유(`reason`): `invalid`(형식 틀림), `no_record`(고칠 기록 없음), `unknown_category`(없는 분류, `unconfirmed` 포함), `memo_failed`, `schedule_failed`, `interrupted`(반영 중 앱이 꺼져 결과를 모름), `is_goal`(일정 명령에 목표 id를 줌), `place_not_found`(좌표 없는 여행 장소를 이름으로 못 찾음), `no_trip`(없는 여행), `memo_too_long`·`note_too_long`(앱 저장 한도 1000자 초과). 글 한도는 앱 메모 저장 한도에 맞춘 1000자다. `categoryId`는 하루 기록 `records[].category.id` 또는 `summary.categories[].id`에 나온 값을 쓴다.

```json
{ "format": "bokki-command", "version": 1, "id": "memo-20261110-1", "action": "addMemo", "text": "우유 사기", "date": "2026-11-10", "time": "18:30" }
{ "format": "bokki-command", "version": 1, "id": "sch-dentist", "action": "addSchedule", "title": "치과", "start": "2026-11-12T15:00+09:00", "end": "2026-11-12T16:00+09:00", "note": "정기 검진" }
{ "format": "bokki-command", "version": 1, "id": "fix-lunch", "action": "updateActivity", "date": "2026-11-10", "startTime": "12:30", "title": "점심", "categoryId": "eating" }
```

## 5. curl 예

```sh
KEY="<연동 키 43자>"
# 최근 기록 읽기
curl -s "https://trip.bokkiyaw.com/activity" -H "Authorization: Bearer $KEY"
curl -s "https://trip.bokkiyaw.com/activity?date=2026-11-10" -H "Authorization: Bearer $KEY"
# 메모 보내기
curl -s -X POST "https://trip.bokkiyaw.com/command" -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  --data '{"format":"bokki-command","version":1,"id":"memo-1","action":"addMemo","text":"우유 사기"}'
# 처리 결과 보기
curl -s "https://trip.bokkiyaw.com/command/result" -H "Authorization: Bearer $KEY"
# 지난 7일 묶음
curl -s "https://trip.bokkiyaw.com/activity/summary?range=week" -H "Authorization: Bearer $KEY"
```

## 6. 저장 암호화 (SEC1110A01·SEC1110A02)

서버는 KV에 넣는 모든 값(`/plan`, `/activity`의 날마다와 추가 칸, `/command/result`)을 서버에서 암호화한다. 명령 큐·키 목록·PIN 검증값은 Durable Object에 두되 사용자 글은 같은 DEK로 잠근 봉투로만 둔다. 값의 형식은 v2(6.1), 감싼 기록은 v3(6.2)이고, v1·평문은 읽어서 옮기기만 한다(16장).

### 6.1 값: 사용자 DEK

- 값은 사용자마다 하나인 32바이트 DEK로 AES-256-GCM 암호화한다: `{"v":2,"iv","ct"}`, AAD는 KV 이름. 모든 값은 주인 키 해시 이름(`plan:<주인>`, `act:<주인>:<HMAC>`, `cmdres:<주인>`, `ext:<주인>`) 아래에 있다.
- 주인 DEK는 주인 키에서 HKDF-SHA256(salt `taption-relay-v1`, info `dek`)으로 정해진다. 서버에 저장하지 않는다.

### 6.2 감싼 기록 v3: 메타데이터도 암호문 안에

- 연결 키·OAuth 토큰마다 `dek:<SHA-256(토큰)>` = `{"v":3,"iv","ct"}` 하나뿐이다. `ct`는 HKDF(토큰, salt `taption-relay-v1`, info `wrap`) 키로 AES-GCM 암호화한 JSON `{kind, scope, expiresAt, master, dek, entry, keyId, source, clientId?}`이고 AAD는 `dek:<해시>`. 범위·만료·주인 해시가 평문으로 보이지 않는다(finding 11). TTL은 만료 시각까지(만료 없음이면 TTL 없음).
- `reg:<해시>`(등록 표시)도 같은 키로 잠근 `{purpose}`다. `tomb:<해시>` = `"1"`은 연결 키였던 토큰의 영구 표시로 TTL이 없다.
- 예전 v2 감싼 기록(`{"v":2,"scope","expiresAt","master","iv","ct"}`, AAD `dek:<해시>|<scope>|<expiresAt>|<주인>`)은 그 키가 처음 쓰일 때 v3로 다시 잠근다. 쓰이지 않은 예전 키는 만료·폐기될 때까지 평문 메타데이터가 남는다(서버가 토큰 없이는 다시 잠글 수 없다).

### 6.3 이름 가리기 (HMAC)

- 이름 키 = HKDF-SHA256(DEK, salt `taption-relay-v3`, info `names`)의 HMAC-SHA256 키. 하루 이름은 `act:<주인>:` + HMAC(`day|YYYY-MM-DD`) 앞 16바이트 hex, 명령 id 표시는 HMAC(`cmd|<id>`) 앞 16바이트 hex.
- Durable Object의 하루 목록은 `{name, date: DEK로 잠근 날짜, exp}`라 서버 운영자도 날짜를 읽지 못한다.

### 6.4 v1 (읽기 호환)

- v1 `{"v":1,"iv","ct"}`: 연동 키에서 HKDF(info `storage`)로 만든 키. 주인 키만 풀 수 있고, 주인이 읽을 때 v2로 다시 잠근다(하루 기록은 남은 TTL을 지켜 HMAC 이름으로 옮긴다).
- 주인이 풀지 못하는 v2·v1 값(변조·다른 이름에서 옮김)은 없는 것으로 보고(`204`) 지운다. 범위 키가 풀지 못하는 값은 지우지 않는다.
- 응답은 인증한 사용자에게 평문 JSON으로 돌려준다(전송은 TLS가 보호한다).

## 7. 키와 범위 (SEC1110A01·AIR1110A02·SEC1110A02)

- 주인 키(43자 base64url)는 앱이 만들어(사용자가 고르지 않음) 키체인에만 두고 앱만 쓴다. 먼저 `POST /register`로 등록해야 한다(12장). AI에는 앱이 만든 연결 키나 OAuth 토큰을 준다.
- 범위: `read` = `GET /activity`·`GET /activity/summary`·`GET /command/result`·`GET /plan`·MCP 읽기 도구. `write` = read + `POST /plan`·`POST /command`·MCP 쓰기 도구. `search` = `GET /kakao/keyword`만. 나머지(`POST`·`DELETE /activity`, `GET`·`DELETE /command`, `POST /command/result`, `DELETE /plan`, `/keys`, `/pin`, `/oauth/code`)는 주인만. 주인은 카카오 중계도 쓸 수 있다.
- 키 수명은 사용자가 앱에서 고른다: 30일·90일·1년·만료 없음, 읽기·쓰기 모두. 서버는 `expiresAt`이 365일 이내이거나 `null`이면 받는다. 이름표는 앱에만 둔다.
- 살아 있는 키 목록은 주인마다의 Durable Object가 정본이다(finding 5). 연결 키·OAuth 연결을 합쳐 20개까지.
- 폐기하면 DO에 영구 폐기 표시를 남기고, 그 연결의 대기 명령을 지우고, KV 감싼 기록을 지운다. `tomb:` 표시가 영원히 남아 그 토큰은 다시 연결 키로도, 주인으로도 등록할 수 없다(finding 10).

| 요청 | 본문·질의 | 응답 |
|---|---|---|
| `POST /keys` | `{"keys":[{"token":"<43자>","scope":"read"\|"write","expiresAt":"ISO8601"\|null}], "pin":"<6자리>"}` 1~3개(REV1110A06, 앱은 하나씩 보낸다) | `201` `{"ok":true,"keys":[{"id","scope","expiresAt","source":"rest"}]}`; `422` 형식 틀림·365일 초과·주인 키와 같음·활성 20개 초과(`not_keys`·`too_many_keys`), `pin_required`(PIN 칸 없음·6자리 아님); `409` `pin_not_set`, 다른 사람의 키·등록된 주인 키·폐기된 키(`key_conflict`·`revoked_key`); `403` `{"error":"wrong_pin","remaining":n}`; `423` `{"error":"pin_locked","retryAfter":초,"lockedUntil":ISO}` + `Retry-After` |
| `GET /keys` | 없음 | `200` `{"keys":[{"id":"<8자 hex>","scope","expiresAt","source":"rest"\|"oauth","client"?}]}` 만료되지 않은 것만. OAuth 연결은 `client`(그 앱이 스스로 적어 보낸 이름이라 확인되지 않은 값, 예: `Claude`), `host`(승인 뒤 돌아간 주소의 호스트, 예: `claude.ai` — 앱은 이름 옆에 이것을 보인다)와 refresh 만료가 보인다 |
| `DELETE /keys?id=<8자 hex>` · `DELETE /keys` | 없음 | `204` 그 연결 또는 전부 폐기(대기 명령도 지움), `400` id 형식 틀림 |

- `expiresAt`은 초 단위 UTC(`2027-02-08T03:00:00Z`) 또는 `null`로 돌려준다. 같은 토큰을 다시 보내면 범위·만료를 바꾼다(PIN 필요).
- 주인 키 바꾸기(이번 배포에서 한 번, finding 1): 앱이 새 주인 키를 `POST /register`로 등록하고, 예전 키도 등록한 뒤(등록하지 않은 키는 지우기도 거절된다) 예전 키로 `DELETE /keys`, `DELETE /activity`, `DELETE /command`, `DELETE /plan`을 부르고 새 키로 바꾼다. 연결은 다시 만든다.

## 8. 기간 묶음 `GET /activity/summary` (AIR1110A02)

`range=week`은 `end`까지 7일, `month`는 30일. `end`가 없으면 오늘(UTC)과 가장 최근에 올린 날 중 늦은 날. 서버에 남아 있는 날만 더한다(보관 기간이 짧으면 덜 덮는다).

```json
{
  "range": "week", "start": "2026-11-04", "end": "2026-11-10",
  "daysCovered": 3, "dates": ["2026-11-08", "2026-11-09", "2026-11-10"],
  "recordedMinutes": 1160, "steps": 10000, "stepDays": 2, "plansScheduled": 3, "plansCompleted": 2,
  "categories": [{ "id": "rest", "title": "휴식", "minutes": 660 }, { "id": "work", "title": "업무", "minutes": 500 }]
}
```

`categories`는 분류 id로 더하고 긴 순, 이름은 가장 최근 날의 것. `steps`는 걸음이 있는 날(`stepDays`)만 더한다.

## 9. 원격 MCP 서버 `POST /mcp` (AIR1110A02·SEC1110A02·AIR1110A03)

- Streamable HTTP, JSON 응답만(SSE 없음, `GET /mcp`는 `405`). JSON-RPC 2.0, 프로토콜 버전 `2025-06-18`. `initialize`·`ping`·`tools/list`·`tools/call`. 알림(`id` 없음)은 `202`. 일괄(배열) 요청은 `-32600`.
- 인증: `Authorization: Bearer <읽기·쓰기 연결 키 또는 OAuth access 토큰>`. 없거나 틀리면 HTTP `401`과 `WWW-Authenticate: Bearer resource_metadata="https://trip.bokkiyaw.com/.well-known/oauth-protected-resource"`(만료·폐기면 `, error="invalid_token"`). OAuth 클라이언트는 이 헤더로 14장 흐름을 시작한다.
- 도구: 읽기 `get_activity(date?)`, `get_summary(range, end?)`, `get_command_results()`; 쓰기 `add_memo`, `add_schedule`, `update_activity`, `hide_record`, `merge_records`, `update_record_time`, `update_schedule`, `delete_schedule`, `update_memo`, `delete_memo`, `add_goal`, `update_goal`, `delete_goal`, `add_trip_stop`, `update_trip_stop`, `delete_trip_stop`, `set_trip_item_status`, `update_sleep`, `set_language`, `set_theme`, `set_map_style`, `set_display_option`, `set_bubble`(칸은 4장과 같고 `id`는 선택, 없으면 `mcp-<UUID>`), `send_trip_plan(plan)`.
- 도구 표시(annotations): 읽기 도구는 `readOnlyHint: true`. 기존 것을 지우거나 바꾸는 도구(`update_*`, `delete_*`, `hide_record`, `merge_records`, `set_*`, `send_trip_plan`)는 `destructiveHint: true`, 새로 더하기만 하는 `add_*`와 보이기만 하는 `set_bubble`은 `false`(finding 7). `set_bubble` 설명과 안내문은 말풍선이 기록을 바꾸지 않는다고 알린다. 클라이언트가 확인을 묻게 된다.
- 믿을 수 없는 글 감싸기: 도구 결과(`content[0].text`와 `structuredContent` 모두)에서 사용자·제3자가 쓴 글(제목·메모·메모 글·장소 이름·분류 이름·목표·여행 일정 등)은 `{"untrusted_user_text":"…"}`로 감싼다. 그대로 두는 값은 칸마다 정한 엄격한 모양뿐이다(REV1110A06): id 칸은 UUID·16진수·`mcp-<UUID>`·기호 없는 영문 한 낱말(24자까지), 날짜·시각 칸은 `YYYY-MM-DD`·`HH:mm`·ISO 시각, `timeZone`은 실제 IANA 시간대, `status`·`source`·`mode`·`type`·`format`·`action`·`range`·`scope`·`reason`·`error`는 서버가 아는 값 목록. 그 밖의 값은 같은 칸이어도 감싼다(예: `memo-20261110-1` 같은 명령 id). 칸 이름이 짧은 영문 낱말(`^[A-Za-z][A-Za-z0-9]{0,31}$`)이 아니면 그 칸은 `"untrusted_fields": [{"name": {"untrusted_user_text": "…"}, "value": …}]`로 옮긴다. `initialize`의 `instructions`가 이 안의 지시·링크·요청을 따르지 말고 사용자가 직접 말한 것만 편집하라고 알린다. REST(`GET /activity` 등) 응답은 형식을 바꾸지 않고 OpenAPI 설명에 같은 주의를 적는다.
- 명령의 `source`: 연결 키로 MCP를 부르면 `mcp`, OAuth 토큰이면 `oauth`. `keyId`는 연결의 `id`.
- `tools/list`는 그 키가 쓸 수 있는 도구만 보여 준다. 읽기 키가 쓰기 도구를 부르면 JSON-RPC 오류 `-32003`. 없는 도구·틀린 인자 모양은 `-32602`, 없는 메서드는 `-32601`, JSON 아님은 `-32700`.
- 쓰기 도구는 `POST /command`·`POST /plan`과 같은 검사·큐·24시간 30개 한도·IP 속도 제한을 쓴다. 검사 실패·한도 초과는 도구 결과의 `isError: true`(본문에 `Error 422: …` 등)로 돌려준다. 한 번에 기존 항목 20개 넘게 바꾸면 앱이 확인을 묻는다(대표 결정).

Claude에 연결하기:

- **Cue — MCP 주소 + 연결 키(CUE1110A01)**: 앱의 「AI 연결 → Cue」에서 읽기/쓰기와 사용 기간을 고르고 앱 비밀번호로 연결 키를 만든다(`POST /keys`). Cue의 MCP 서버 추가 화면에 `https://trip.bokkiyaw.com/mcp`를 넣고 인증(요청 헤더)에 `Authorization: Bearer <연결 키>`를 넣는다. 앱이 Cue에 자동으로 잇지 않는다. Cue가 헤더 인증을 받지 않으면 Claude와 같은 `/mcp/<연결 키>` 주소도 쓸 수 있다.
- **claude.ai(웹·앱) 사용자 지정 커넥터 — 주소 하나(추천, CLD1110A01)**: 앱의 「AI 연결 → Claude → 연결 주소 만들기」가 앱 비밀번호를 받아 연결 키를 만들고 `https://trip.bokkiyaw.com/mcp/<연결 키>`를 복사한다. 설정 → 커넥터 → 「사용자 지정 커넥터 추가」에 붙여 넣고 인증은 「로그인 없음」. 서버는 이 주소의 키를 `Authorization: Bearer`와 같게 보되 AI 연결 키만 받고 주 키는 `403`이며, 이 주소에는 OAuth 안내(`WWW-Authenticate`)를 보내지 않는다. 주소가 곧 키이므로 앱의 연결 키 관리에서 끊으면 바로 막힌다.
- **claude.ai(웹·앱) 사용자 지정 커넥터 — OAuth**: 설정 → 커넥터 → 「사용자 지정 커넥터 추가」, 주소 `https://trip.bokkiyaw.com/mcp`. Claude가 동적 등록 → 승인 화면을 연다. 앱의 「AI 연결 → Claude」에서 받은 8자 연결 코드와 PIN을 넣고 승인한다(14장). 고정 키는 넣지 않는다.
- **Claude Code**: OAuth로 `claude mcp add --transport http taption https://trip.bokkiyaw.com/mcp` 뒤 `/mcp`에서 인증(돌아오는 주소는 `http://localhost:<포트>/…`라 등록할 수 있다). 또는 연결 키를 헤더로: `claude mcp add --transport http taption https://trip.bokkiyaw.com/mcp --header "Authorization: Bearer <키 43자>"`.
- **Claude API**(Messages API MCP 커넥터): `mcp_servers: [{"type":"url","url":"https://trip.bokkiyaw.com/mcp","name":"taption","authorization_token":"<연결 키 43자>"}]`.
- **Gemini CLI**: `~/.gemini/settings.json`에 `{"mcpServers":{"taption":{"httpUrl":"https://trip.bokkiyaw.com/mcp","headers":{"Authorization":"Bearer <키 43자>"}}}}`. 연결이 안 되는 Gemini 앱은 안내문 복사·붙여넣기로 쓴다.

## 10. ChatGPT (AIR1110A02·AIR1110A03)

- **커넥터(앱·개발자 모드) — OAuth**: ChatGPT 설정 → 앱과 커넥터 → 고급(개발자 모드) → 만들기, MCP 서버 주소 `https://trip.bokkiyaw.com/mcp`, 인증 「OAuth」. ChatGPT가 동적 등록 뒤 승인 화면을 연다. 앱의 연결 코드와 PIN을 넣는다.
- **맞춤 GPT Actions — 연결 키**: GPT 편집 → 작업 → 「URL에서 가져오기」에 `https://trip.bokkiyaw.com/openapi.json`, 인증은 「API 키」·「Bearer」에 읽기 또는 쓰기 연결 키. 문서는 AI가 부르는 경로(`GET /activity`, `GET /activity/summary`, `POST /command`, `GET /command/result`, `GET`·`POST /plan`)만 담는다. GPT Actions의 OAuth는 클라이언트 ID·비밀을 손으로 넣는 방식이라 쓰지 않는다(동적 등록이 없다).
- **피클·기타 REST**: 연결 키를 앱이 만들어 안내문과 함께 복사한다(클립보드는 이 기기만·10분).

## 11. 개인정보

하루 기록은 사용자가 고른 기간(최대 30일) 동안 서버에 머물고, 공유를 끄면 앱이 바로 지운다. 명령과 결과는 최대 7일 머문다. 좌표·경로·주소는 어떤 수준에서도 보내지 않는다. 개인정보 처리방침(PRIVACY.md)과 App Store 개인정보 항목에 이 보관을 반영해야 한다(남은 일).

## 12. 등록 `POST /register` (SEC1110A02)

- 앱이 키(32바이트 무작위, base64url 43자)를 만들고 그 키로 `Authorization: Bearer <새 키>`를 붙여 부른다. 본문: `{}`(주인), `{"purpose":"search"}`(지도 검색 전용 설치 키, PIN 없음). 예전 앱이 보내는 `pinVerifier`는 무시한다(PIN은 13장 `POST /pin`).
- 이미 등록된 키를 다시 보내면 IP 하루 수에 세지 않고 `200`이다(REV1110A06). 앱은 켤 때마다 불러도 된다. 새 등록은 IP마다 하루 20번(IPv6는 /64로 묶음), 서버 전체 하루 500번.
- 응답: `201` `{"ok":true,"purpose","created":true}` · `200` 이미 같은 목적으로 등록됨 · `422 low_entropy` 서로 다른 글자 20개 미만 · `409` 다른 목적으로 이미 등록됨(`purpose_conflict`) 또는 연결 키였던 토큰(`key_conflict`) · `400` 본문 틀림(`bad_purpose`) · `429` IP당 1분 20번(`POST_LIMIT`) 또는 IP당 하루 20번(Durable Object `ip:<SHA-256(IP)>`, 다음 날 비움). 앱은 2xx·409를 성공, 422를 약한 키로 본다.
- 등록은 주인 키 해시 이름의 Durable Object에 기록되고(정본, 즉시 일관), KV에 `reg:<해시>`(잠근 목적) 표시를 남긴다. 만료는 없다.
- 등록되지 않은 43자 키는 모든 경로에서 `401 {"error":"unregistered"}`다. "모르는 키 = 새 주인"은 더 없다(finding 3). 빌드 305 이하 앱의 `/plan`은 앱을 업데이트할 때까지 멈춘다(대표 결정).

## 13. PIN (SEC1110A02·SEC1110A03)

- 사용자가 따로 PIN을 정하지 않는다(PIN1110A01, 대표 결정 2026-11-10). 앱은 앱 비밀번호 6자리(= 백업 비밀번호)를 기기에서 먼저 확인하고, `HMAC-SHA256(key = iCloud 키체인으로 동기화되는 32바이트 무작위 값, msg = "bokki-ai-pin-v1" 0x00 앱 비밀번호)`의 앞 4바이트를 10⁶으로 나눈 나머지 6자리를 PIN으로 보낸다. 서버 저장소·pepper가 새도 이 무작위 값 없이는 앱 비밀번호를 되찾을 수 없다. 앱 비밀번호를 바꾸면 앱이 `currentPin`으로 서버 PIN을 따라 바꾼다. OAuth 승인 화면에는 앱이 연결 코드 옆에 보여 주는 「승인 화면 PIN」을 넣는다. 예전에 따로 정한 PIN이 서버에 있으면 앱이 한 번만 그 PIN을 받아 바꾼다.
- 앱은 6자리 PIN을 TLS로 서버에 보낸다. 서버는 PIN을 저장하지 않고 검증값만 둔다: 서버가 만든 무작위 salt 16바이트와 `HMAC-SHA256(key = Worker 비밀 PIN_PEPPER, msg = salt || PIN UTF-8)`. 이것을 사용자 DEK로 잠가 Durable Object에 둔다. 비교는 상수 시간. 응답에는 PIN을 넣지 않는다. (서버 PBKDF2는 Workers 운영 환경의 반복 수 상한과 무료 CPU 10ms 때문에 쓰지 않는다. 대표 결정.)
- `POST /pin` (주인): 처음 정하기 `{"pin":"123456"}`. 이미 있으면 바꾸기 `{"pin":"<새 PIN>","currentPin":"<지금 PIN>"}`. `currentPin`도 같은 방법으로 확인하고 틀리면 잠금 수에 센다. 응답: `200 {"ok":true}`; PIN 형식 틀림 `422 pin_required`; 바꾸는데 `currentPin` 없음 `422 current_pin_required`; 지금 PIN 틀림 `403 wrong_pin`; 잠김 `423 pin_locked`.
- `GET /pin` (주인) → `200 {"set":true|false,"locked":true|false,"retryAfter"?:초,"lockedUntil":ISO|null}`. `retryAfter`는 잠겼을 때만 있다. 앱은 이것으로 PIN이 있는지 확인한다(기기의 표시만 믿지 않는다).
- `POST /pin/reset` (주인 키만, 본문 `{}` 또는 없음; 연결 키·OAuth 토큰·검색 키는 `403 forbidden`): PIN을 잊었을 때. PIN 검증값과 틀린 횟수·잠금을 지우고, **모든** 연결 키와 OAuth 연결(access·refresh 토큰)을 끊고 그 연결들이 보낸 대기 명령을 지우며, 대기 중인 연결 코드·승인 코드도 못 쓰게 한다. 응답 `200 {"reset":true,"revokedKeys":n}`(`n` = 끊은 연결 수). 그 뒤 앱이 `POST /pin {"pin"}`으로 새 PIN을 정한다(`currentPin` 없이). 한도: `POST_LIMIT`과 주인마다 하루 3번, 넘으면 `429 {"error":"rate_limited","retryAfter"}`. 끊긴 키는 다시 쓸 수 없으므로 연결은 새로 만든다.
- `POST /register`의 `pinVerifier`는 무시한다(예전 앱 호환). PIN은 `POST /pin`으로만 정한다.
- `POST /keys` 본문의 `"pin"`과 OAuth 승인 화면의 PIN을 같은 방법으로 확인한다.
- 15분 안에 5번 틀리면 `/keys`·`/pin` 바꾸기·OAuth 승인이 15분 잠긴다(Durable Object가 셈, 동시에 보내도 넘지 않음). 오류: 틀림 `403 {"error":"wrong_pin","message","remaining":n}`, 잠김 `423 {"error":"pin_locked","message","retryAfter":초,"lockedUntil":ISO}` + `Retry-After`, PIN 없음 `409 pin_not_set`, PIN 칸 없음 `422 pin_required`, Worker 비밀 `PIN_PEPPER`가 없음 `503 pin_check_unavailable`(시도로 세지 않음).
- **배포 전(대표)**: `npx wrangler secret put PIN_PEPPER --config wrangler.local.toml`에 무작위 32바이트 이상 값을 넣는다(예: `openssl rand -base64 48`의 출력). 이 값을 바꾸거나 잃으면 모든 사용자의 PIN이 맞지 않게 되어 앱에서 `POST /pin/reset` 뒤 PIN을 다시 정해야 한다. 저장소·로그에 남기지 않는다.

## 14. OAuth 2.1 커넥터 (AIR1110A03)

| 요청 | 내용 |
|---|---|
| `GET /.well-known/oauth-protected-resource`(·`/mcp`) | RFC 9728: `resource` = `https://trip.bokkiyaw.com/mcp`, `authorization_servers` = [주소], `scopes_supported` = `read`·`write` |
| `GET /.well-known/oauth-authorization-server` | RFC 8414: `authorization_endpoint`·`token_endpoint`·`registration_endpoint`, `code_challenge_methods_supported: ["S256"]`, `grant_types_supported: authorization_code·refresh_token`, `token_endpoint_auth_methods_supported: none·client_secret_post·client_secret_basic` |
| `POST /oauth/register` | RFC 7591 동적 등록. `redirect_uris` 1~10개(https, 또는 `http://localhost`·`127.0.0.1`·`[::1]`), `client_name`(100자, 보이지 않는 글자·방향 바꿈 글자는 지움, 「AI 연결」에 보임), `token_endpoint_auth_method`(기본 `client_secret_basic`, `none`이면 비밀 없음). `201` `{client_id, client_secret?, …}`. KV `oclient:<id>`에 7일, 연결에 쓰이면 1년(쓰이는 동안 30일마다 다시 셈). IP마다 하루 10번·서버 전체 하루 200번, 넘으면 `429` |
| `POST /oauth/code` (앱, 주인 키) | 8자 연결 코드(`23456789ABCDEFGHJKLMNPQRSTUVWXYZ`, 40비트) `201 {"code","expiresAt","expiresIn":600,"expiresInSeconds":600}`. 10분, 한 번. PIN이 없으면 `409 pin_not_set`. 기록은 KV가 아니라 코드마다의 Durable Object에 두고 서버 비밀(`PIN_PEPPER`)과 코드로 잠근다(코드 40비트만으로는 풀 수 없다) |
| `GET /oauth/authorize` | 승인 화면(한국어·영어, 외부 자원 없음). `response_type=code`, `client_id`, `redirect_uri`(등록한 것과 같아야), `code_challenge`+`code_challenge_method=S256`(필수, plain 거절), `state`, `scope`(`read`·`write`, 없으면 write), `resource`(선택). 앱 이름(확인되지 않았다고 알림)·승인 뒤 돌아갈 주소의 호스트·범위를 보이고 연결 코드·PIN을 받는다. 요청이 틀리면(`response_type`·PKCE·scope·resource) 저절로 돌려보내지 않고 `400` 오류 화면에 돌아가는 링크만 보인다 |
| `POST /oauth/authorize` | CSRF: `__Host-tp_csrf` 쿠키(Secure·HttpOnly·SameSite=Strict, 10분)와 폼 `csrf`가 같아야 하고 `Origin`이 있으면 이 주소여야 한다. 연결 코드 → PIN(13장 잠금 공유) → 코드 한 번 쓰기 → 승인 코드(2분, 한 번) → `redirect_uri?code&state&iss`로 돌아간다 |
| `POST /oauth/token` | `authorization_code`(+ `code_verifier`, S256 확인, `client_id` 일치, `redirect_uri`는 보냈으면 같아야 하고 없어도 됨) 또는 `refresh_token`. `200 {"access_token","token_type":"Bearer","expires_in":28800,"refresh_token","scope"}`. 틀리면 `400 invalid_grant`, 클라이언트 인증 실패 `401 invalid_client`, 쓰기 예산 초과 `429`, 저장소가 쓰기를 거절하면 `503 temporarily_unavailable`(승인 코드는 그대로라 2분 안에 다시 바꿀 수 있다) |

- 화면 헤더: `Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Cache-Control: no-store`. 승인 뒤에는 302 대신 `<meta http-equiv="refresh">` 화면으로 돌아간다(브라우저가 form-action으로 다른 주소로의 리디렉트를 막지 않게).
- 토큰: 48바이트 base64url 64자(주인·연결 키와 길이가 달라 등록할 수 없다). access 8시간, refresh 90일. KV 쓰기를 아끼려고(REV1110A06) refresh 토큰은 쓸 때마다가 아니라 하루에 한 번 바뀐다: 바뀐 지 하루가 안 됐으면 같은 refresh 토큰을 돌려주고(KV 쓰기 1번), 하루가 지났으면 새 토큰으로 바꾸고 90일을 다시 센다(2번). 바뀐 뒤 1분 동안은 예전 토큰으로 온 요청(동시에 온 것·다시 보낸 것)에도 같은 새 토큰을 돌려주고, 그 뒤에 예전 토큰이 다시 오거나 승인 코드가 두 번 쓰이면 그 연결을 끊는다. 범위 기본 write.
- 연결 하나 = DO 키 목록의 한 줄(`GET /keys`에 `source:"oauth"`, `client`, `expiresAt`=refresh 만료). 명령의 `keyId`는 이 연결 id, `source`는 `oauth`. `DELETE /keys?id=`로 끊으면 access·refresh가 바로 `401`.
- 설정 방법은 9장(claude.ai·Claude Code)과 10장(ChatGPT).

## 15. 한도와 보안 모델 (SEC1110A02)

| 한도 | 값 | 어디서 |
|---|---|---|
| IP당 모든 요청 | 1분 120번 (`REQUEST_LIMIT`), 카카오는 1분 60번(`KAKAO_LIMIT`). IPv6는 /64로 묶는다 | 인증 전(카카오도) |
| IP당 본문 있는 쓰기 | 1분 20번 (`POST_LIMIT`) | `/register`·`/keys`·`/pin`·`/pin/reset`·`/oauth/code`·`/oauth/register`·승인 POST·데이터 POST·MCP 쓰기 도구 |
| 새 등록(`/register`) | IP당 하루 20번, 서버 전체 하루 500번. 이미 등록된 키는 세지 않음 | DO |
| OAuth 클라이언트 등록 | IP당 하루 10번, 서버 전체 하루 200번 | DO |
| 주인 키 요청 | 1분 120번·하루 2,000번(GET·DELETE 포함) | DO |
| 연결(연결 키·OAuth) 요청 | 연결들 함께 1분 120번·하루 2,000번, 연결 하나는 1분 60번·하루 1,000번. 주인 키 몫과 따로라 연결이 다 써도 앱은 막히지 않는다 | DO |
| KV 쓰기 | 주인마다 하루 600번(`daily_write_limit`), 서버 전체 하루 `KV_DAILY_WRITE_BUDGET`(기본 900, `write_budget_exhausted`). 넘으면 쓰기 전에 `429` | DO |
| 주인마다 명령 | 24시간 30개, 큐 50개 | DO |
| 주인마다 말풍선(`setBubble`) | 24시간 48개, 큐 48개(명령 30개와 따로) | DO |
| 카카오 | 키마다 하루 500번, IP마다 하루 2,000번(UTC 날짜, `kakao_daily_limit`) | DO |
| PIN | 15분에 5번 틀리면 15분 잠금. 초기화는 주인마다 하루 3번 | DO |
| 연결 | 연결 키·OAuth 합쳐 20개, `POST /keys` 한 번에 3개 | DO |
| 하루 기록 | 날짜가 다른 하루 62개 | DO |
| 본문 | 64KB(승인·토큰·등록 폼 8KB), 스트림으로 세다 넘으면 끊음 | Worker |

모든 `429`는 `Retry-After` 헤더와 본문 `retryAfter`(초)를 준다(SEC1110A03). Cloudflare 속도 제한 바인딩은 남은 시간을 알려 주지 않아 그 경우는 창 길이인 60초다. 명령 한도는 `retryAfterSeconds`도 함께 준다(예전 앱 호환). 승인 화면의 429는 HTML이라 헤더만 있다.

- 지우기는 지울 것이 없으면 KV를 건드리지 않는다(`DELETE /plan`은 먼저 읽고, `/activity`는 DO 목록을 본다).
- 서버가 보는 것: 키 해시, 연결 id(8 hex), 명령 받은 시각, 하루 기록 만료 시각. 날짜·범위·만료·주인 연결·글은 모두 DEK나 토큰 키로 잠겨 있다. 서버 운영자는 사용자 키 없이 값을 풀 수 없다(DEK는 주인 키에서 정해지고, 연결 키·토큰·연결 코드가 감싼 사본만 있다).
- 프롬프트 주입: MCP 결과의 사용자 글은 감싸고(9장), 바꾸는 도구는 `destructiveHint`, 앱은 20개 넘게 바꾸면 묻는다. 위험한 동작은 서버에 없다(4장).
- 클립보드(앱): 키가 든 복사는 이 기기만·10분 만료.
- 검색 키는 카카오만, OAuth 토큰은 주인이 될 수 없고, 폐기한 키는 영원히 다시 쓸 수 없다.

## 16. 예전 자료 옮기기 (SEC1110A02)

배포 때 한꺼번에 옮기지 않는다. 주인마다 Durable Object의 `legacy` 표시(`keys`·`queue`·`days`)를 보고 그 자료가 처음 필요할 때 한 번 옮긴다. 지우지 않고 다시 잠근다.

| 예전 자료 | 언제 | 어떻게 |
|---|---|---|
| `act:<주인>:YYYY-MM-DD` (v2) | 하루 기록을 처음 읽거나 쓸 때(주인·범위 키 누구든) | KV `list`로 찾아 DEK로 풀고 HMAC 이름으로 옮긴다(남은 TTL 유지). 요청 하나에 10일씩, DO 잠금으로 한 번에 한 요청만 옮긴다(그동안 온 `POST /activity`는 `503 migrating`, 읽기는 예전 이름에서 계속 읽는다). 새 이름이 이미 있는지는 KV가 아니라 DO 하루 목록으로 본다(있으면 그것이 새것이라 예전 것은 버림) |
| 같은 이름 (v1) | 주인 키가 처음 올 때 | 범위 키는 v1을 못 풀어 한 번만 시도하고 남긴다. 그동안 그 날은 범위 키에 안 보인다 |
| `plan:`·`cmdres:` (v1·평문) | 그 값을 읽을 때 | v1은 주인이, 평문은 누구든 v2로 다시 잠근다(TTL은 plan 3일·결과 7일로 다시 셈). 평문 예외는 2026-11-14 끝까지, 그 뒤 평문은 없는 것으로 보고 지우지 않는다 |
| `cmd:<주인>` (KV 큐, 배열 또는 `{commands,sent}`) | 명령 경로를 처음 쓸 때 | DO 큐로 옮기고(`keyId: null`, `source: "legacy"`, 24시간 수 합침) KV는 지운다. v1이면 주인이 옮긴다 |
| `keys:<주인>` (KV 키 목록) | 주인이 `/keys`를 처음 부를 때 | DO 목록으로 옮기고 키마다 `tomb:` 표시를 남긴 뒤 KV는 지운다 |
| `dek:<해시>` v2 감싼 기록 | 그 키가 쓰일 때 | 목록에 없던 키(경쟁 잔여)도 DO 목록에 넣고(보이고 끊을 수 있게) v3로 다시 잠근다. 단 주인이 「모두 끊기」(`DELETE /keys`)나 PIN 초기화를 한 뒤에는 목록에 없던 예전 키를 받아들이지 않고 영구 `tomb:`로 바꾼다(REV1110A06) |
| v2 폐기 표시 `{"revoked":true}` | 그 키가 쓰일 때 | 영구 `tomb:`로 바꾸고 지운다. 그 전에 30일 TTL이 끝난 폐기 키는 등록 요구 때문에 그대로 `401`이다 |

주인 키 바꾸기(7장)로 예전 주인 이름의 자료는 앱이 지운다. 그래서 대부분의 예전 자료는 옮겨진 뒤 곧 지워진다.
