# 외부 AI ⇄ 중계 서버 ⇄ 앱 강화 계획 (요청 ID: AIX1114A01)

## Context

대표 지시(2026-11-14 `/plan`): ① AI가 할 수 있는 업무 전부 추가 ② 앱→서버→AI 업무 요청과 회신 강화 ③ AI가 처리한 것을 서버에 규칙(JSON)으로 계속 유지하고 앱이 같은 버전을 받아 1차로 적용 ④ AI 기능 전체 리팩토링·패키지화.

조사로 확인한 현재 상태:
- AI 명령은 50개. 하나 더하려면 11곳을 고쳐야 한다(`validate.js`·`mcp.js`·`openapi.js`·Swift enum·Raw·parser·토글·apply·undo·app state·안내문).
- 일(task)과 그 일로 보낸 명령이 이어져 있지 않고, 회신은 300자 글뿐. 일 목록은 KV에 잠금 없이 통째로 써서 동시 완료 때 덮어씀(AIR1114A01). 일 상태는 「AI」 탭을 열 때만 갱신. 끝나도 알림 없음. 거절된 명령은 「AI가 한 일」에 안 남음. 푸시 없음.
- AI가 만든 규칙은 결제 문자 정규식 하나뿐이고 기기에만 있음. 나머지 판단(가게→분류, 영수증 낱말, 이체·카드대금, 일정 제목→활동 등)은 코드에 박힌 표. 서버에 기한 없이 남는 사용자 자료는 아직 없음.
- AI 코드 약 25개 파일이 `extension AppModel`/`extension MapHomeView`로 앱에 직접 붙어 있음. 새 앱 파일은 `project.pbxproj`에 손으로 등록해야 함(패키지 파일은 불필요).

대표 결정(객관식 답): 규칙은 **바로 적용·되돌리기 가능**, 위험한 일도 **전부 바로 실행**(항목별 토글), **푸시까지 넣기**, **AI 전체를 패키지로**. 여행 공유는 **설계만 적고 구현은 따로**.

## 0단계: 먼저 끝낼 것 (계획 승인 직후)

- 서버 배포: RDX1114A01(지난 날짜 노선 확인 거절). 337이 계속 올리는 것을 막음.
- TestFlight 338: 337 뒤 변경(OCF·AIB·RDF·RDX·HSW1114A01) 반영.

## 설계 요약

### A. 패키지 구조 (AI 전체)

새 패키지 `Packages/TaptionAssistant`(타깃 4개) + `Packages/TaptionLedgerCore`.

| 타깃 | 담는 것 | 의존 |
|---|---|---|
| `TaptionRules` | 규칙 모델·코덱·평가기·엔진 버전 | Foundation |
| `TaptionLedgerCore` | `LedgerEntry`·`LedgerCategory`·`LedgerTrip`·`LedgerMessageParser`(Vision 제외)·`PaymentInbox.Item` 등 값 타입 | PlanStore, WatchSync |
| `TaptionAssistantProtocol` | 명령·일·질문·앱 상태 DTO, `AssistantFields`, `actions.json`, 가리기 | PlanCore, Rules |
| `TaptionAssistantKit` | 중계 클라이언트, 등록·키, 명령 실행기·저널, 폴링, 일 큐, 규칙 동기화, 동작 등록부, 로그·되돌리기, 푸시 처리, **호스트 프로토콜** | Protocol, Store, LedgerCore |
| `TaptionAssistantUI` | AI 화면(SwiftUI) | Kit |

- 방향: 앱 → UI → Kit → Protocol → Rules. 패키지는 `AppModel`·`MapHomeView`·`LedgerBook`을 모른다.
- 호스트 프로토콜(Kit에 정의, 앱 `TaptionPlan/UX/AssistantHost*.swift`가 구현): `AssistantDataHost`(snapshot·commit), `PlanHost`, `RecordHost`, `PlaceTripHost`, `LedgerHost`, `SettingsHost`, `SystemHost`, `RulesHost`.
- 주입: `AssistantEnvironment{defaults, session, secrets, host, clientInfo, files, now}`. 기존 `AssistantRegistration.Environment`·`AssistantPreferenceStore`를 일반화.
- 문구: `MapHomeLanguage` 대신 이미 공개된 `AppLanguagePreference.ResolvedLanguage.text(ko,en)`(TaptionWatchSync)를 씀. `scripts/l10n/extract.py`에 패키지→타깃 지도(`PACKAGE_TARGETS`)를 넣어 AI 문구가 위젯·Watch 카탈로그로 새지 않게 함.
- 앱에 남는 것: `AITaskProducer`/`ReceiptPhotoScanner`(Photos·Vision), `RideLineTasks`, `LedgerIntents`/`SiriIntents`, 호스트 어댑터, 푸시 등록, `MapHomeView+Assistant.swift` 접착 코드.
- 방침·가드 변경: `DEVELOPMENT.md`·`AGENTS.md`의 「앱 전용 코드는 패키지로 옮기지 않는다」를 새 경계로 바꾸고 `docs/ARCHITECTURE_ROADMAP.md`에 ADR-005 추가. `scripts/check-app-engine-import-boundary.sh`에 "Assistant·LedgerCore 패키지는 엔진·UIKit(UI 타깃 외)·MapKit·Photos·AppIntents를 import하지 않는다" 규칙 추가.

### B. 규칙 저장소

- 형식: `{format:"bokki-rules", version:<정수>, engine:1, rules:[{id,type,appliesTo,enabled,match,result,source{by:ai|user,keyId,taskId},note,createdAt,updatedAt}]}`. `version`은 서버가 변경마다 1씩 올림.
- 앱은 `appliesTo > RuleEngine.version`이거나 모르는 `type`, 해석 못 하는 `match/result`는 **건너뛰고**(지우지 않음) ack에 `skipped`로 보고 → "앱이 적용 가능한 수준의 룰만 적용".
- 1차 규칙 종류와 적용 자리:

| type | match → result | 앱에서 평가하는 곳 |
|---|---|---|
| `payment_text`(기존) | 정규식+견본 → 지출/수입/넣지 않음 | `LedgerMessageRules.match` ← `PaymentTextCapture.process` (`Core/LedgerIntents.swift`) |
| `skip_word` / `text_ignore` / `internal_transfer` | 낱말 포함 → 넣지 않음·내부 | `PaymentAlertSources.skipWord`, `isPaymentCandidate` 앞, `LedgerOwnAccounts.isOwnTransfer` 옆 |
| `own_account` / `source_switch` | 계좌 이름 / 앱별 지출·수입 | `LedgerOwnAccounts.names`, `PaymentAlertSources.allows` |
| `merchant_category` | 가게 낱말 → 분류(+이름) | `LedgerCategory.guess`(`Core/LedgerCore.swift:51`) 앞. 맞으면 AI 다듬기 일(`LedgerIntents.swift:157`)을 생략 |
| `receipt_hint` | 낱말 → 영수증 여부·분류 | `ReceiptPhotoScanner.isReceipt` |
| `calendar_title` | 제목 → 상세 분류 | `CalendarTitleClassification.detail` |
| `place_pair_mode` | 장소 쌍 → 수단(+노선) | 이동 교정 조회(사용자 교정이 우선) |
| `ride_line` | 승하차 정류소 → 번호·노선 | `BusRouteCheck.known`·`SubwayLineChoice` 조회, `route_check` 일 만들기 전 |

- 우선순위: 사용자 규칙 → AI 규칙(새것부터) → 코드에 박힌 표(그대로 예비로 둠).
- 서버 저장: **Durable Object**(기한 없음, 쓰기 직렬화, KV 쓰기 예산 안 씀). `rulesMeta{version,…}`, `rule:<id>`(본문은 봉인), `ruleGone:<id>`. 상한 500개·규칙당 1.5KB. 「전부 지우기」 경로에 규칙 삭제 포함.
- 주소·도구: `GET /rules?since=v`(같으면 304), `POST /rules`(AI, 20개까지), `POST /rules/ops`(앱의 사용자 편집: enable/disable/delete/put, `baseVersion`), `DELETE /rules`, `POST /rules/ack{version,engine,skipped}`. MCP `get_rules`·`put_rules`·`delete_rule`·`set_rule_enabled`. 기존 `add_payment_rule`은 규칙 저장소로 쓰는 별칭으로 유지.
- 검증(서버 JS와 Swift가 같은 견본 파일 `server/trip-relay/test/fixtures/rules.json`으로 시험): 종류별 허용 필드, 낱말 2~40자·10개, 숫자 9자리 연속 금지, 정규식 300자·중첩 반복·역참조 금지, 앱은 견본 일치 + 시간 제한 시험.
- 동기화: 기기 `rules.json`(서버 사본+버전)·`rules-outbox.json`(대기 중 사용자 편집). `RuleSync.run()`을 명령 확인·백그라운드·푸시 처리에서 호출: outbox 올리기 → `GET /rules?since` → ack. ack가 닿으면 양쪽 버전이 같다. `get_rules`가 `appVersion`·`skipped`를 함께 돌려줘 AI가 기기 적용 상태를 안다.
- 이전: 첫 실행 때 기기의 결제 규칙·일정 제목 분류·내 계좌·넣지 않을 낱말·앱별 스위치를 서버로 올림(2xx 뒤에만 완료 표시). 334~338로 내려가도 되게 한 릴리스 동안 옛 키도 함께 씀.
- 기록·되돌리기: 규칙이 들어오면 「AI가 한 일」에 `rule.<type>` 항목. 되돌리기=끄기, 따로 삭제. 새 화면 「AI 규칙」(목록·스위치·삭제·"앱 업데이트 필요" 표시). 규칙이 만든 가계부 기록에 `ruleID`를 남김.
- AI 안내: 일을 끝낸 뒤 같은 판단이 반복될 것이면 `put_rules`로 저장, 가장 좁은 조건으로, 한 번의 애매한 사례로는 만들지 않음, 먼저 `get_rules`로 중복 확인. 일 `context.ruleHint`로 맞는 종류를 알려 줌.
- 개인정보: 본문 봉인, 계좌 같은 숫자는 거절·가림, 좌표는 받지 않음. `PRIVACY.md`에 "기한 없이 서버에 남는 첫 자료" 문단 추가.

### C. 요청·회신 파이프라인

- 일 목록을 DO로 옮김(`task:<tag>`, KV 문서에서 한 번 가져오기). 상태 `waiting → processing → asked → done|failed|expired`. `asked`는 AI가 사용자에게 물었을 때이고 답이 올라오면 `waiting`으로 돌아감.
- 30분 넘은 `processing`은 `waiting`으로(시도 +1), 3번 넘으면 `failed(timeout)`. 가져가기는 `limit`(기본 5)과 종류 우선순위. `finishTask`는 가져간 연결만(아니면 409). `/tasks/claim`·`/tasks/result`는 쓰기 권한으로.
- 연결 고리: 모든 명령에 선택 `taskId`. 일 결과에 `outcome{commandIds,entryIds,ruleIds,askedQuestionId,needsUser}`. 명령 결과에 `keyId`·`taskId`, 보관 50 → 200. 종류별 `context` 스키마(`TASK_CONTEXT`).
- 앱: `AITaskQueue.refresh`를 5분 확인·백그라운드·푸시에서도 호출, 못 올린 일은 매번 재시도, 끝남·실패 때 알림 한 번(묶어서), 거절된 명령도 「AI가 한 일」에 사유와 함께, 일마다 맡은 AI 이름 표시, 일을 눌러 "이 일로 바뀐 것"을 보고 한 번에 되돌리기.
- 대기열: `queue` 50 → 100, 넘치면 조용히 버리지 않고 `429 queue_full`.
- 푸시(APNs): 앱에 `aps-environment`·`remote-notification` 추가, AI 연결이 있을 때만 등록, 토큰은 `POST /push/token`(봉인 저장). 서버 `src/apns.js`가 `.p8`로 ES256 JWT를 만들어 전송(`ctx.waitUntil`). 보내는 때: 명령 도착(조용히, 2분에 1번), 질문·승인(보이게), 일 끝남(조용히, 60초 묶음), 규칙 변경(조용히). 푸시에는 내용을 싣지 않고 종류만. 폴링은 예비로 유지. 비밀 값이 없으면 서버는 푸시를 건너뜀.
  - **대표가 직접 할 일**: App ID에 Push Notifications 켜기, APNs 인증 키 만들기, `npx wrangler secret put APNS_KEY_P8`·`APNS_KEY_ID`·`APNS_TEAM_ID` 입력. 키는 제가 다루지 않음.

### D. AI가 할 수 있는 일 전부

- 먼저 고칠 곳을 11 → 3으로 줄임: 서버 `src/actions.js` 한 곳에서 검증·MCP 도구·OpenAPI·`list_actions`를 만들고(`since`=필요 빌드, 낮은 빌드면 `422 app_too_old`), `actions.json`을 뽑아 Swift 등록부와 일치 시험. 앱은 `AssistantOperation` 프로토콜(`spec`·`init?(fields:)`·`apply(host:)`)과 `AssistantFields`. 기존 50개는 그대로 두고 새 동작만 이 방식.
- 토글·「AI가 할 수 있는 일」 목록(묶음별)·안내문은 등록부에서 생성. 되돌릴 수 없는 동작은 「지우는 일」 묶음에 따로 보이고 로그에 "되돌릴 수 없음".
- 묶음(빌드 하나씩):
  1. 가계부: 지출에 여행·몫·메모·날짜·낸 사람, 받은 문자 고르기(지출/수입/넣지 않음/내부), 여행 가계부 만들기·지우기·인원·정산, 환율, 알림 앱 스위치, 넣지 않을 낱말
  2. 일정: 분류·중요·반복·목표, 완료·미루기·옮기기·멈추기, 시간 있는 여행 일정 추가·수정·이동·삭제, iOS 캘린더로 내보내기
  3. 기록: 탑승 확인·거절, 수단 추가(자전거 등), 상세 기록 넣기, 미확인 꼬리 자르기, 직접 넣은 기록 삭제, 기록↔일정 연결, 메모 시각·종류·스티커, 지도 메모
  4. 분류·장소: 분류 순서·삭제·색, 장소 종류·층, 내 정류장, 하루 카드 항목, 화랑이 꾸미기
  5. 설정: 화면 스위치들, 카카오 지도, 보폭, 알림·하루 카드 시각, Watch 설정, 화면 열기 대상 추가(CSV·GPX·영상은 화면 열기만)
  6. 시스템·지우는 일: 새로고침·클라우드 동기화, 위치 수집 끄기, 사진 끄기, 캘린더 끊기, 추적 멈춤, 기존 승인 항목(공유 범위·보관 기간·백업 등)을 바로 실행으로
- 결정대로 전부 바로 실행하되, 기술적으로 그렇게 못 하는 것: 권한 **켜기**(위치·사진·알림)는 iOS 창이 필요해 끄기만 가능. 한 번에 20건 넘는 묶음 확인(`AssistantBatchPolicy`)은 유지.
- 6묶음 시작 전에 다시 여쭐 것: 앱 잠금 켜기·PIN 바꾸기(잘못되면 본인이 못 들어감), 전부 지우기·복원(되돌릴 수 없음).

### E. 여행 공유 (설계만, 구현은 따로 지시)

- 여행 하나에 주인 한 명. 주인만 공유 만들기·지우기·비밀번호 바꾸기·참여자 내보내기. 참여자는 다시 공유할 수 없음.
- 링크 + 비밀번호로 키를 만들어 서버에는 암호화된 문서만. 비밀번호 여러 번 틀리면 잠금. 계정 없음. 지울 권한은 주인 기기의 "주인 열쇠". 보관 기한(여행 끝 +30일) 자동 삭제.
- 실시간 함께 쓰기: 여행 화면을 연 동안 서버(DO)와 연결 유지. **칸 단위 잠금**(일정 하나·지출 한 건, 2분 임대·연장, 끊기면 자동 해제). 순서 바꾸기는 그 날에 잠깐 잠금.
- 가계부: 공유 / 개인(공개) / 개인(비공개). 비공개는 서버에 올리지 않음. "내 지출 전부 공유" 스위치(가족용, 사람별), 여행 기본값으로도. 정산은 공유 지출만, 모두에게 같은 결과. 송금 완료 표시 공유, 주인의 정산 마감, "정산 안 함" 여행.
- 공지(대표 추가 2026-11-14 「3시까지 호텔로 이런 식으로 공지 날리면 알람 받아서 확인해야 함」): 일행 누구나 짧은 공지를 보내면 다른 사람 모두에게 알림이 가고, 각자 「확인」을 눌러야 한다. 보낸 사람은 누가 확인했고 누가 아직인지 본다. 확인 안 한 사람에게는 한 번 더 알린다. 시각이 든 공지(「3시까지」)는 그 시각 전에 다시 알릴 수 있게 시각 칸을 따로 둔다. 화면을 닫고 있어도 받아야 하므로 푸시(P6)가 전제다. 공지는 여행 문서와 같은 키로 암호화하고, 푸시에는 내용을 싣지 않고 「새 공지」만 보낸 뒤 앱이 받아서 보여 준다.
- 대표가 밝힌 전체 그림(2026-11-14): 회원가입 없이 링크+비밀번호, **여행에서만**, 기존 중계 서버 사용, 보안 우선.
  - 계획: 여럿이 동시에 편집. 잠금은 **내가 고치는 날짜·시간 칸만**. 누가 어디를 고치는 중인지 보임(문서 공동 편집 방식).
  - 참여자: 여행 카드에 누가 붙었는지 보임. 닉네임은 각자 정함(여행 모드에서만 쓰는 이름).
  - 여행 중 가계부 실시간 공유. 여행 뒤에는 일정 전체와 공유 가계부를 **각자 자기 앱에 저장**하고, 공유 가계부에서 내 몫을 받아 내 가계부에 반영.
  - 위치: 여행 모드에서만, 본인이 켠 동안만 친구에게 실시간으로. 보내는 것은 **현재 위치와 활동 대분류만**(경로·상세 분류·건강 자료는 보내지 않음). 언제든 끄고 켤 수 있고 여행이 끝나면 자동으로 꺼짐. 쓰임: 공항에서 모일 때 다들 어디쯤인지, 각자 다니다가 정한 곳에 모일 때.
  - 지도: 친구는 내가 고른 캐릭터가 아닌 다른 캐릭터로 나오고 머리 위에 닉네임. 여럿이면 겹칠 수 있음.
  - 말풍선=공지: 캐릭터 위 말풍선(일상의 말풍선과 같은 것)에 그 사람이 남긴 공지가 뜸. 주고받는 글은 **공지만**(자유 채팅 없음). 「몇 시에 어디서」처럼 시각·장소를 담을 수 있음.
- 우리 서버로 되는지(검토): 됨. 지금 서버의 Durable Object가 여행 하나를 방 하나로 맡아 연결(WebSocket)을 유지하고 쓰기를 차례로 처리한다. 화면을 연 동안은 연결로 실시간, 닫혀 있을 때는 푸시(P6). 계정이 없으므로 링크의 비밀 값+비밀번호로 만든 키로 **기기에서 암호화**해 서버는 내용(계획·지출·위치·공지·닉네임)을 읽지 못하게 한다. 서버가 아는 것은 방 id, 참여 기기 수, 시각, 크기뿐.
- 보안에서 지킬 것: 비밀번호 틀림 횟수 제한·잠금, 링크 비밀 값은 서버 로그에 남지 않게 주소의 `#` 뒤에 둠, 주인 열쇠는 주인 기기에만, 참여자 내보내기 때 키를 바꿈(나간 사람이 이후 내용을 못 읽게), 위치는 최신 한 점만 두고 지난 것은 서버에 쌓지 않음, 방은 여행 끝 +30일에 자동 삭제, 푸시에는 내용 없음.
- 한도(무료 요금제 기준, 확인 필요): 위치를 사람마다 20~30초에 한 번, 움직일 때만 보내면 하루 요청 한도 안. 여행 방이 동시에 많아지면 유료 전환이 필요할 수 있음.
- 심사·법: 위치 공유가 다시 들어오므로 애플 심사는 「본인이 켠다·누구에게 공유 중인지 보인다·언제든 끈다·여행이 끝나면 꺼진다」로 설명. 국내 위치정보법상 신고 대상인지는 출시 전에 확인해야 한다(서버가 위치를 읽지 못하는 구조여도 대상일 수 있음).
- 정할 것: 인터넷 없을 때 편집, 마감 뒤 수정, 공개 개인 지출을 남이 고칠지, 앱 없는 일행의 몫, 예산을 공유·개인으로 나눌지.
- 이번 계획과의 연결: DO 저장·푸시·`TaptionLedgerCore` 값 타입을 그대로 씀.

## 단계 (각 단계는 TestFlight 빌드 하나 이하)

| 단계 | 서버 배포 | 앱 | 시험 | 대표 기기 확인 |
|---|---|---|---|---|
| P0 가드 | 없음 | 패키지 뼈대, l10n 지도, 경계 규칙, ADR-005 | 경계·구조·번역 점검 | 없음 |
| P1 서버 등록부 | `actions.js`(동작 동일) | 없음 | `npm test` + 옛·새 검증기 대조 시험 | 연결된 AI로 명령 한 번 |
| P2 일 DO 이전 | 일 DO·`outcome`·`taskId`·쓰기 권한·`queue_full` | 없음 | 동시 완료·넘겨받기·`asked`·만료·이전 시험 | 338 기기가 계속 일을 올리고 봄 |
| P3 규칙 | `/rules*`·MCP 도구·안내 | `TaptionRules`·`RuleSync`·이전·파이프라인 훅·「AI 규칙」 | 공유 견본(`npm`·`swift test`), 결제 문자 시험 | 문자 → AI가 규칙 → 같은 문자를 앱이 스스로 읽음 → 끄기 → 버전 일치 |
| P4 패키지 이동 | 없음 | 값 타입 → Protocol → Kit 전송 → Kit 적용 → UI 순으로 옮기기만 | 옮긴 시험은 `swift test`, 나머지 xcodebuild, 구조 지표 증가 없음 | 연결·명령·되돌리기·PIN |
| P5 파이프라인(앱) | 없음 | 일↔명령 묶음, 거절 기록, 갱신, 알림, 맡은 AI | Kit `swift test`(가짜 호스트) | 백그라운드에서 일이 끝나면 알림 |
| P6 푸시 | `apns.js`·`/push/token` | 권한·등록·처리 | 가짜 APNs 시험, 앱 라우팅 시험 | 대표가 키 입력 뒤 잠긴 폰에 질문 푸시, 조용한 푸시로 30초 안 적용 |
| P7~P12 동작 묶음 1~6 | 등록부 항목(`since`) | 동작·호스트 메서드 | 동작별 검증·적용·되돌리기·일치 시험 | 묶음마다 대표 동작 3~4개 |
| P13 정리 | KV 일 코드·옛 별칭 제거 | 옛 키 제거 | 전체 | 없음 |

- 서버는 P13 전까지 덧붙이기만 한다. 현장의 334~338이 쓰는 `/tasks`·`/command*`·`/app`·`/answers`·`/polish`·`/activity` 모양은 바꾸지 않는다.
- P1~P3은 P4보다 먼저(규칙은 새 패키지의 새 코드라 이동에 기대지 않음).
- 단계마다 AGENTS.md 절차: 요청 ID를 `temp.md`에 먼저 기록, 결과는 `test.md`, 로그는 `build/validation/<ID>/`, 서버 배포·TestFlight는 대표 지시 뒤.

## 고칠 주요 파일

- 서버: `server/trip-relay/src/validate.js`, `state.js`, `store.js`, `mcp.js`, `openapi.js`, `index.js`, 새 `actions.js`·`rules.js`·`apns.js`, `test/*.mjs`
- 앱: `TaptionPlan/UI/Assistant*.swift` 전부, `UX/AITaskQueue.swift`, `UI/AITaskPanel.swift`, `Core/LedgerMessageRules.swift`, `Core/LedgerIntents.swift`, `Core/LedgerCore.swift`·`LedgerCapture.swift`·`LedgerReview.swift`, `Core/PaymentAlertSources.swift`, `Core/CalendarTitleClassification.swift`, `Core/BusStopCheck.swift`, `TaptionPlanApp.swift`, 권한 파일 2개
- 새 패키지: `Packages/TaptionAssistant`, `Packages/TaptionLedgerCore`
- 가드·문서: `scripts/l10n/extract.py`, `scripts/check-app-engine-import-boundary.sh`, `DEVELOPMENT.md`, `AGENTS.md`, `docs/ARCHITECTURE_ROADMAP.md`, `PRIVACY.md`, `project.pbxproj`(패키지 참조 한 번)

## 다시 쓰는 것

- 봉인 저장·DO 직렬화·가져오기 패턴: `state.js`의 `enqueue`/`ensureQueue`
- 되돌리기: `AssistantEditDelta.difference`, `AssistantPreferenceChange`, `AssistantAppChange`
- 값싼 확장 표: `setSetting`(`SETTINGS`·`AssistantSetting`), `openScreen`(`SCREENS`)
- 배운 규칙의 본보기: `LedgerTollRepeat`의 `[from→to: Rule]`, `MovementCorrectionEngine`
- 주입 이음매: `AssistantRegistration.Environment`, `AssistantSecretStore`

## 위험과 대비

- 줄 수 상한(현재 230,895 / 상한 248,288): 이동은 중립, 규칙 +2,500, 동작 묶음 +6,000 예상. P9 전에 기준선 올리기를 대표께 따로 승인받음.
- 나쁜 AI 규칙이 조용히 잘못 분류: 모든 규칙을 기록·끄기 가능, 규칙별 적용 횟수, 사용자 규칙 우선, 정규식은 견본 일치 필수.
- 읽기 전용 키로 붙은 AI는 일을 못 가져가게 됨: `claimable:false`로 알리고 쓰기 키를 요청하게 안내.
- 푸시는 도착이 보장되지 않음: 폴링 유지, 푸시에 기대는 정확성 없음.
- 패키지 이동 회귀: 옮기기만 하는 커밋과 동작 바꾸는 커밋을 섞지 않음.
- 확인 못 한 가정: Worker에서 APNs(HTTP/2) 호출, 알림 덮어쓰기 식별자 동작(P6 시작 때 먼저 시험), 묶음별 모델 함수가 화면 상태 없이 불리는지(각 묶음 시작 때 30분 확인).

## 검증

- 서버: `cd server/trip-relay && npm test`(동시 완료·규칙 견본·APNs 가짜·검증기 대조 포함)
- 패키지: `swift test`(`Packages/TaptionAssistant`, `Packages/TaptionLedgerCore`)
- 앱: 시뮬레이터 `xcodebuild test`(AI·가계부 묶음), `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json`, `scripts/check-app-engine-import-boundary.sh`, l10n `extract → check → generate`
- 연결 확인: 이 세션의 커넥터로 `get_ai_tasks`·`get_rules`·`put_rules`·명령 왕복
- 기기: 위 표의 단계별 항목(대표 확인). 시뮬레이터 결과와 구분해 `test.md`에 기록
