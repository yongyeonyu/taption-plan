# 공통 규칙 설계 (SRL1116A01)

대표 지시(2026-11-16): 문자 메시지 규칙·알림 규칙·AI가 한 것 가운데 사람들에게 공통으로 쓸 수 있는 것은 서버에서 업데이트를 받아 쓰고, 대표가 확인해 수집·배포할 수 있게 하며, 약관에 적는다.

## 1. 이미 있는 것 (다시 만들지 않음)

| 있는 것 | 자리 |
|---|---|
| 사용자별 규칙 저장소(11종, 버전, 304, ack, 끄기·삭제) | 서버 `src/rules.js`·`state.js`, 앱 `AssistantRuleStore`, 계획 `docs/AI_RELAY_PLAN.md` B절 |
| 규칙 모양 검사(서버·앱 같은 견본) | `src/rules.js` `RULE_TYPES`, `RuleShape`, `test/fixtures/rules.json` |
| 결제 문자 처리 순서 | `PaymentTextCapture.process`: 건너뛰기 낱말 → 서버 규칙(skip·ignore·내부 이체) → `LedgerMessageRules.match`(AI 정규식) → 급여 → `parse` → 확인 필요 |
| 「알림 규칙」에 해당하는 것 | 앱별 지출·수입 받기 `source_switch`, 알림 글 안내·광고 거르기 `text_ignore`, 알림·문자 읽기 `payment_text` (문자와 알림은 같은 처리 길을 탄다) |
| 개인정보 보호 | 낱말에 숫자 9자리 금지, 정규식 안전 검사, `AITaskQueue.mask`, 규칙 본문 봉인 |

없던 것: **사용자 사이를 잇는 길**. 한 사람의 AI가 알아낸 형식이 다른 사람에게 가지 않고, 대표가 볼 수도 없었다.

## 2. 대표 결정 (2026-11-16 객관식)

- 후보 올리기 동의: **「AI 연결 때 함께 묻기」** — AI 연결 화면에 스위치 하나, 기본 꺼짐. 켜야만 올린다(약관 동의에 묶지 않음).
- 올리는 범위: **가게→분류까지 포함**. 단, 서버는 서로 다른 기기 **2대 이상**이 올린 것만 검토 목록에 보인다(동네 가게 이름 노출 방지).
- 알림 규칙 범위: **앱별 기본값(`source_switch`) 포함**. 사용자가 직접 정한 값은 항상 먼저다. 앱별 값은 사용자 선택이라 기기에서 올리지 않고 대표가 직접 써서 내보낸다.
- 공통 규칙 받기: **기본 켜짐**(내려받기만, 기기 정보를 보내지 않음). 설정에서 전체·규칙별로 끈다.

## 3. 전체 흐름

```
사용자 기기 ──(동의 시) 거른 후보──▶ 서버 후보 창고 ──(대표 Mac) candidates·draft──▶ 초안
                                                                        │ 검토·견본 글 직접 작성
앱 ◀── 서명한 묶음(GET /shared/rules) ◀── 서버 보관 ◀── publish(서명) ◀───┘
```

서버는 후보를 모을 뿐 **승인 전에는 누구에게도 배포하지 않는다.** 배포는 대표 Mac의 서명 키로 서명한 묶음만 가능하다.

## 4. 공통 규칙 묶음

- 형식: `{format:"bokki-shared-rules", version, engine:1, issuedAt, rules:[{id,type,match,result,note?}]}`를 **글 그대로** `payload`로 두고, 같은 글에 대한 Ed25519 서명을 `signature`(base64)로 둔다. 글을 다시 직렬화하지 않으므로 서명이 어긋날 일이 없다.
- 종류: `payment_text`·`text_ignore`·`receipt_hint`·`merchant_category`·`source_switch`. 사람마다 다른 `own_account`·`skip_word`·`internal_transfer`·`calendar_title`·`place_pair_mode`·`ride_line`은 공통으로 내보내지 않는다(서버 검증이 거절, 앱이 한 번 더 거름).
- 판 번호: 정수, **오르기만 한다.** 서버는 같거나 낮은 판을 거절(409), 앱은 지금보다 낮거나 같은 판을 받지 않는다.
- 무결성: 서버(공개 키 `SHARED_RULES_PUBLIC_KEY`)와 앱(Info.plist `SHARED_RULES_PUBLIC_KEY`)이 각각 서명을 확인한다. 서버가 뚫려도 서명 없는 규칙은 앱이 쓰지 않는다. 서명 개인 키는 대표 Mac의 `~/.bokki-shared-rules/signing.pem`(권한 600)에만 있고 서버·저장소에 없다. 앱에 공개 키가 비어 있으면 공통 규칙을 쓰지 않는다.
- 한도: 묶음 100KB·규칙 400개, 규칙당 기존 1.5KB·낱말 10개 등 `cleanRule` 한도 그대로. 정규식은 기존 안전 검사.
- 거두기(잘못된 규칙): `admin.mjs withdraw <id>`가 그 규칙을 뺀 **새 판**을 서명해 올린다. 앱은 새 판을 받으면 묶음 전체를 바꾸므로 그 규칙이 사라진다. 서버 비밀값을 지워 관리 길을 닫을 수도 있다.

## 5. 앱이 받는 때와 순서

- 때: 앱이 켜질 때, **하루에 한 번**(`checkInterval` 24h), 「공통 규칙」 화면을 열거나 받기를 켤 때는 바로. 백그라운드 작업·푸시는 만들지 않는다(iOS가 허용하는 시점이 아니면 하지 않음).
- 길: `GET /shared/rules?since=<판>` 설치 검색 키로(AI 연결 없이도). 같으면 304. 기기 정보·사용 정보를 싣지 않는다(헤더는 기존 `x-bokki-client`뿐).
- 우선순위(앞이 이긴다): 기기에서 정한 값(앱별 스위치·건너뛰기 낱말·내 계좌) → **내가 정한 규칙** → **내 AI가 만든 규칙(새것부터)** → **공통 규칙** → 코드에 박힌 표. 구현: `AssistantRuleSnapshot`에 공통 규칙을 뒤에 붙이고, 결제 정규식은 `LedgerMessageRules.match(shared:)`가 기기 규칙 뒤에 시도한다.
- 끄기: 「AI 규칙 → 공통 규칙」에서 **전체 받기 스위치**(끄면 쓰지 않음, 받은 묶음은 남김)와 **규칙별 스위치**. 공통 규칙이 만든 결정을 지우는 것이 아니라 앞으로 쓰지 않는다.
- 이 빌드 이전의 앱은 `/shared/*`를 모르므로 영향이 없다.

## 6. 수집(후보 올리기)

올리는 것(`type`·`match`·`result`의 알려진 칸만): 결제 문자 정규식 패턴과 종류(지출·수입·넣지 않음), 넣지 않을 글 낱말(+보낸 앱 이름), 영수증 낱말, 가게 낱말→분류.
**올리지 않는 것**: 받은 글 원문·견본 글, 금액, 사람 이름, 계좌·카드 번호, 좌표·위치, 규칙에 붙은 이름·제목·메모, 규칙의 id·시각·만든 연결, 사용자가 직접 정한 규칙, 계정·기기 식별.

기기에서 거르기(`SharedRuleFilter`, 서버 `cleanCandidate`와 같은 표를 같은 견본 `test/fixtures/shared-rules.json`으로 시험):
1. 내 AI가 만들었고 켜져 있으며 올릴 수 있는 종류 4가지만.
2. 모양 검사 통과 후 알려진 칸만 남김(견본 글·이름·제목·사유 제거).
3. 개인 정보로 보이면 통째로 제외: 숫자 4자리 이상, 가린 글자(`*`·`＊`), `@`, 「이름님」(고객·회원·본인·가입자·이용자 제외). 정규식은 글자 그대로 맞추는 부분만 같은 검사.
4. 같은 규칙은 한 번만(지문), 한 번에 20개·하루 40개(서버).

서버가 한 번 더 거르고(앱을 믿지 않음), 후보를 **지문별로 하나**만 저장한다: 본문, 올린 기기 수, 처음·마지막 날(날짜까지). **누가 올렸는지는 어디에도 적지 않는다.** 같은 기기의 같은 규칙은 사용자 쪽 인스턴스에 지문만 남겨 한 번만 센다. 90일 동안 다시 안 올라온 후보는 지운다. 후보 창고 2,000개 한도.

## 7. 대표의 검토·배포 (웹 화면 없음, 로컬 스크립트)

`scripts/shared-rules/admin.mjs`(대표 Mac, 서버 관리 토큰·서명 키는 `~/.bokki-shared-rules/`에만).

| 명령 | 하는 일 |
|---|---|
| `keygen` | 서명 키 쌍 생성, 공개 키 표시 |
| `candidates [--min N]` | 기기 N대(기본 2) 이상이 올린 후보를 번호와 함께 표시 |
| `draft 1,3,4` | 고른 후보를 초안(`drafts/next.json`)에 더함. 결제 정규식은 **대표가 지어낸 견본 글**을 직접 채워야 함(실제 문자 금지) |
| `status` | 서버 묶음과 초안 비교 |
| `publish` | 초안을 다음 판으로 서명해 올림 — 이 순간부터 모든 앱이 받는다 |
| `withdraw id,…` | 그 규칙을 뺀 새 판을 올림 |
| (서버) `DELETE /shared/admin/candidates?fps=` | 검토 뒤 후보 버림 |

## 8. 서버 비밀값·끝점

비밀값(`wrangler secret put`): `SHARED_RULES_PUBLIC_KEY`(base64 32바이트 공개 키), `SHARED_RULES_ADMIN_TOKEN`(32자 이상). 둘 다 없으면 관리 길은 503이고 받기는 `version 0`만 돌려준다.

| 끝점 | 누가 | 내용 |
|---|---|---|
| `GET /shared/rules?since=` | 등록된 앱(검색·주 키) | 서명한 묶음, 같으면 304 |
| `POST /shared/candidates` | 앱의 주 키(동의한 사용자만 호출) | 후보 20개까지 |
| `GET /shared/admin/bundle`·`GET /shared/admin/candidates?min=`·`DELETE …candidates?fps=`·`POST /shared/admin/publish` | 관리 토큰 | 대표 스크립트 |

## 9. 배포 순서 (대표 지시 뒤)

1. `node scripts/shared-rules/admin.mjs keygen` → 공개 키 기록.
2. `cd server/trip-relay && npx wrangler secret put SHARED_RULES_PUBLIC_KEY`, `… SHARED_RULES_ADMIN_TOKEN`(토큰은 `~/.bokki-shared-rules/admin.json`에도).
3. `npx wrangler deploy` (새 Durable Object 클래스 없음 — 기존 `UserState`의 새 이름 `shared:rules` 인스턴스, migration 없음).
4. `TaptionPlan/AppSecrets.local.xcconfig`에 `SHARED_RULES_PUBLIC_KEY = <공개 키>` → 앱 빌드·TestFlight.
5. 앱이 나간 뒤 후보가 모이면 `candidates` → `draft` → `publish`.
서버를 먼저 배포하고 앱을 나중에 내보낸다(앱이 없는 경로를 부르지 않게).

## 10. 약관·개인정보처리방침

저장소에 이용약관 문서는 없었고 앱 안에도 약관·방침 화면의 글이 없다(`SettingsView`에 「데이터와 개인정보」 제목만 있음). 있던 것은 `PRIVACY.md`뿐. 이번에 `PRIVACY.md`에 공통 규칙 문단을 더하고 `TERMS.md`를 **초안**으로 새로 만들었다. 앱 안의 글은 AI 연결 화면의 동의 스위치 설명(초안 표시)과 「공통 규칙」 화면의 안내다. 법적 확정은 대표 몫이다.

## 11. 검증과 남은 것

서버 `npm test`, `TaptionRules` 패키지 시험(서버와 같은 견본), 앱 `SharedRuleStoreTests`. 못 한 것은 `test.md`에 있다: 서버 배포, 서명 키 생성, 실기기 확인, 12개 언어 번역(새 문구는 영어로 보임, 메인 세션이 `scripts/l10n` 절차로 처리).
