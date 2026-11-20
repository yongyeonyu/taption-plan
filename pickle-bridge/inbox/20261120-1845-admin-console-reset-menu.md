---
id: 20261120-1845-admin-console-reset-menu
created_at: 2026-11-20T18:45+09:00
status: pending
request_id: ADM1120A03
title: 운영 페이지에 「초기화」 탭을 따로 만들기 — 공지·팩 배포 상태를 한 번에 되돌리고 되돌리기까지
from: 비야
basis: 대표 직접 지시 (2026-11-20 18:43 통화) — 「어, 별도 메뉴로 해가지고 초기화 기능을 넣어줘.」 / 같은 통화 앞부분에서 「지금은 베타 테스트 기간이니까 초기화도, 초기화를 할 거야, 내가.」
---

## 0. 이 요청의 범위 (먼저 읽기)

- **만드는 것**: `tools/admin-console`에 **`초기화` 탭 하나를 새로** 만듭니다. 지금 올라간 **공지**와 **시즌 팩 배포 상태**를 골라서 한 번에 되돌리고, 방금 되돌린 것을 **한 번에 되돌리기(복원)**까지 합니다. 베타 기간에 대표가 반복해서 쓸 화면입니다.
- **만들지 않는 것**: 새 서버·새 서비스·새 인증. 이 콘솔은 지금처럼 이 맥의 `127.0.0.1`에만 열리고, 실행마다 새로 만드는 `?t=` 토큰과 `X-Admin-Token`, Host 검사(421)를 그대로 씁니다. 중계 서버(`server/trip-relay`) 코드도, 앱 코드도 고치지 않습니다.
- **기기 초기화는 이 화면의 일이 아닙니다.** 콘솔은 앱 기기에 닿지 못합니다. 기기에 이미 받아 둔 팩·읽은 공지 기록은 앱의 「모든 데이터 삭제」가 지웁니다. 화면에 그 한 줄을 안내로 적고, 서버 쪽 상태만 되돌립니다(3절 「서버 상태」/「기기 상태」 구분).

## 1. 지금 저장소에서 확인한 것 (2026-11-20 18:44, `origin/main` `c1e184c2` 기준 — 착수 때 다시 확인하고 쓰십시오)

| 곳 | 지금 있는 것 | 이번에 볼 점 |
|---|---|---|
| `tools/admin-console/index.html:14~18` | `<nav>`에 탭 버튼 셋: `공지`(data-tab="notices")·`시즌 팩`(packs)·`설정`(settings) | **여기에 `초기화`(data-tab="reset")를 네 번째로 더한다** |
| `index.html:22·65·78` | `<section id="notices">`·`<section id="packs">`·`<section id="settings">` 패널, 뒤에 `<section class="panel">`(기록/로그) 하나 | 패널 하나를 새로 추가하고 같은 방식으로 숨긴다 |
| `index.html:100` 근처 | `confirm` 대화상자(올리기 확인) `<button value="no">`/`<button value="yes" class="primary">` | 초기화도 이 확인 상자를 재사용한다(새 모달 체계를 만들지 않는다) |
| `server.mjs:271~` (`routes`) | `GET /api/state`·`POST /api/config`·`GET /api/announcements`·`POST /api/announcements/preview`·`POST /api/announcements/publish`·`GET /api/packs`·`/api/packs/build`·`/publish`·`/schedule`·`/withdraw` | 초기화 라우트 셋을 같은 표에 더한다(5절) |
| `server.mjs`의 `exclusive(...)`·`upload(...)`·`log(...)`·`dryRun` | 한 번에 하나만 도는 잠금, R2 올리기(`npx wrangler r2 object put … --remote`), 기록, 연습 모드 | 초기화도 **`exclusive`로 감싸고 `upload`로만** 올린다. 새 업로드 경로를 만들지 않는다 |
| `POST /api/announcements/publish`의 `baseVersion` 검사 | 읽은 뒤 서버 공지가 바뀌었으면 409 | 초기화에도 같은 **버전 충돌 검사**를 둔다(6절) |
| `POST /api/packs/publish`의 순서 | 파일 먼저, 카탈로그 나중에 + `rangeCheck`(206) | 초기화는 **카탈로그만** 만진다(파일은 그대로 둔다, 4절) |
| `server.mjs`의 `BUILD_ROOT` 저장 | 기본 저장 폴더는 `build/admin-console/`(`BUILD_ROOT`, `server.mjs:23`, 시험은 `ADMIN_CONSOLE_BUILD_ROOT`로 바꿈)이고 그 아래 `announce-<시각>/`·`schedule-<id>-<시각>/`·`withdraw-<id>-<시각>/`에 남긴다 | 초기화 전 상태도 **같은 자리(BUILD_ROOT 아래)** 에 백업한다(4절) |
| `server.test.mjs`(CI의 `node --test tools/admin-console/server.test.mjs`) | 가짜 응답·연습 모드로 공지·팩 흐름을 시험 | 초기화 시험을 같은 방식으로 더한다(7절) |
| `README.md` 「할 수 있는 것」 | 공지·시즌 팩·공개 기간·설정 | `초기화` 항목을 한 절 더한다 |

## 2. 대표 시나리오 — 이것이 합격선

1. 콘솔을 열고 **`초기화` 탭**을 누르면 지금 서버 상태가 한눈에 보인다: 공지 `version`과 항목 수, 카탈로그의 팩 목록(id·version·기간).
2. 되돌릴 범위를 고른다(체크 셋): `공지 비우기`, `팩 카탈로그 비우기`, `기간(운영 기간) 지우기`. 기본값은 **셋 다 켜짐**(베타 초기화의 뜻이 대개 "처음 상태로")이고, 무엇이 사라지는지 옆에 결과가 바로 보인다.
3. `미리보기`를 누르면 **바뀌기 전/후 JSON이 나란히** 나오고, 검사를 통과해야 `초기화 실행` 버튼이 켜진다(지금 공지 흐름과 같은 규칙).
4. `초기화 실행` → 확인 상자에서 한 번 더 → 실행. 끝나면 「무엇을 되돌렸고 앱은 최대 5분(엣지 캐시)+30분(앱 확인 간격) 안에 받는다」가 기록에 남는다.
5. 잘못 눌렀으면 **`방금 초기화 되돌리기`** 버튼 하나로 초기화 직전 상태를 그대로 다시 올린다(새 탭을 오가도 마지막 것 하나는 남아 있다).
6. 연습 모드(`--dry-run`)에서는 올리지 않고 무엇을 올릴지만 기록에 남는다. 실패하면 아무것도 바뀌지 않는다(서버 상태가 반쯤 지워지는 일이 없어야 한다).

## 3. 「초기화」가 뜻하는 것 (범위를 정확히)

**서버 상태(콘솔이 되돌린다)**
- `공지`: `GET /public/announcements`가 돌려주는 문서. `공지 비우기` = 항목 목록을 비우고 **`version`은 하나 올려** 올린다(그대로 두면 앱이 304로 안 바뀐 줄 안다).
- `시즌 팩 카탈로그`: `packs/season/index.json`. `팩 카탈로그 비우기` = `packs: []`로 올린다. `기간 지우기` = 각 팩의 `schedule` 칸을 지워 매니페스트 기간으로 돌린다(팩 항목은 남긴다).
- **R2의 팩 파일(`packs/season/<id>/<version>/…bpack`)은 지우지 않는다.** 공개 버킷의 개체 삭제는 되돌릴 수 없고, 카탈로그에서 빠지면 앱은 어차피 쓰지 않는다. `파일까지 지우기`를 넣더라도 **기본 꺼짐 + 별도 확인 문구**로 두고, 이번 범위에서는 넣지 않아도 된다(넣을 경우 8절에 적어 회신).

**기기 상태(콘솔이 못 건드린다)**
- 이미 내려받은 팩·설치본·읽음 표시·팩 메모는 기기에 남는다. 카탈로그에서 빠져도 앱은 가진 팩을 계속 그릴 수 있다(`SeasonPackStore`는 지우지 않고 보관).
- 그래서 화면에 이 한 줄을 적는다: **「기기에 이미 받은 팩은 앱의 설정 › 모든 데이터 삭제로 지웁니다.」** 대표가 베타 초기화를 "기기까지" 뜻할 때 헷갈리지 않게.

## 4. 안전장치 (이 넷은 빠지면 안 됩니다)

1. **먼저 백업, 그다음 올리기.** 실행 직전의 공지 JSON과 카탈로그 JSON을 `BUILD_ROOT`(`build/admin-console/`, `.gitignore`의 `build/`) 아래 `reset-<yyyy-MM-ddTHH-mm-ss>/before-announcements.json`·`before-index.json`에 남기고, 새로 올릴 문서도 같은 폴더에 둔다. 되돌리기는 그 `before-*`를 그대로 다시 올리는 일이다(다시 계산하지 않는다 — 계산이 바뀌면 "그때 그대로"가 아니다). **백업 폴더는 `git add` 하지 않는다.**
2. **버전·시각 충돌 검사.** 실행 요청에 미리보기 때 읽은 `baseVersion`(공지)과 `baseCatalogUpdatedAt`(카탈로그, 없으면 `JSON.stringify` 해시)을 실어 보내고, 그 사이 서버가 바뀌었으면 409로 멈춘다(지금 공지 올리기와 같은 문구 톤).
3. **순서와 실패 처리.** 공지와 카탈로그는 서로 다른 키라 한쪽만 성공할 수 있다. 그래서 ① 백업 → ② 공지 → ③ 카탈로그 순으로 하고, ②에서 실패하면 ③을 하지 않고, ②성공·③실패면 기록에 「공지가 먼저 비워졌습니다. 되돌리기로 복구하십시오」를 남긴다. 어느 경우에도 되돌리기 버튼은 살아 있어야 한다.
4. **연습 모드·잠금·기록.** `--dry-run`에서는 `upload`가 올리지 않으므로 그대로 두고, `exclusive("초기화", …)`로 다른 작업과 겹치지 않게 하고, 모든 단계를 `log(...)`로 남긴다.

## 5. API (같은 `routes` 표에 더하기)

```
GET  /api/reset/state     → { announcements: {version, count, items:[{id,title,updatedAt}]},
                              catalog: {updatedAt, packs:[{id, version, schedule}]},
                              lastReset: {dir, at, scopes} | null, dryRun }
POST /api/reset/preview   ← { scopes: {notices:bool, packs:bool, schedules:bool} }
                          → { before, after, errors:[] }            // 공지·카탈로그 두 문서 모두
POST /api/reset/apply     ← { scopes, baseVersion, baseCatalogHash, confirm: "초기화" }
                          → { dir, announcements:{version}, catalog:{packs}, dryRun }
POST /api/reset/restore   ← { dir }                                // 생략하면 마지막 초기화
                          → { restored:["announcements","catalog"], dir, dryRun }
```

- `confirm`은 글자 그대로 `"초기화"`를 받아야 한다. 화면 입력칸에 그것을 치게 하고, 서버에서도 검사한다(브라우저에서만 막지 않는다).
- **`dir`은 서버가 정한다(중요).** `restore`의 `dir`을 본문에서 그대로 받아 폴더를 열면 `../../` 같은 값으로 **아무 파일이나 읽어 공개 버킷에 올리는 길**이 된다. ⑴ `dir`은 `^reset-\d{4}-\d{2}-\d{2}T[\d-]+$` 모양만 받고, ⑵ `resolve(BUILD_ROOT, dir)`가 **`BUILD_ROOT` 안에 있는지**(`relative()`가 `..`로 시작하지 않는지) 확인하며, ⑶ `before-announcements.json`·`before-index.json` **두 파일만** 읽는다(폴더의 다른 파일·하위 폴더 무시). `dir`을 생략하면 메모리에 둔 **마지막 초기화**만 쓴다.
- `scopes`가 모두 `false`면 422.
- `lastReset`은 프로세스 메모리와 `build/` 폴더 양쪽에서 찾는다(콘솔을 다시 켜도 마지막 백업으로 되돌릴 수 있게).

## 6. 화면 (`index.html`·`app.js`·`app.css`)

- 탭 순서: `공지` · `시즌 팩` · **`초기화`** · `설정`. 기존 탭 배선(`data-tab` ↔ `section id`) 그대로 쓰고, 새 화면에서만 쓰는 스타일은 `app.css`에 붙인다.
- 패널 구성: ① 지금 상태 표(공지 version·항목 수 / 팩 id·version·기간) ② 범위 체크 셋 ③ `미리보기` → 전/후 JSON 두 칸 ④ `초기화 실행`(미리보기 전에는 비활성) + 확인 상자 ⑤ `방금 초기화 되돌리기` ⑥ 기기 쪽 안내 한 줄.
- 위험한 동작임이 보이게: 실행 버튼은 기존 `.primary`가 아니라 붉은 계열 클래스 하나(`.danger`)를 새로 두고, 확인 상자 문구에 **무엇이 사라지는지**를 문장으로 적는다.
- 한국어 문구만 쓰고(지금 콘솔과 같게), 영어를 새로 넣지 않는다.

## 7. 시험 (`server.test.mjs`)

가짜 응답·`--dry-run`만 쓴다. 실제 R2 업로드는 시험하지 않는다(지금과 같게).

1. `scopes` 셋 다 켬 → 미리보기의 `after`가 «공지: 빈 목록 + version+1» · «카탈로그: `packs: []`»인지.
2. `schedules`만 켬 → 팩 항목은 남고 `schedule` 칸만 사라지는지.
3. `confirm`이 틀리면 422, `scopes`가 다 꺼짐이면 422.
4. `baseVersion`이 서버와 다르면 409(그리고 아무것도 올라가지 않았는지).
5. `apply` 뒤 `BUILD_ROOT/reset-*`에 `before-announcements.json`·`before-index.json`이 있는지, `restore`가 그 내용을 그대로 다시 올리는지.
5-1. `restore`의 `dir`이 `..`·절대경로·모양 밖 값이면 **400**이고, `BUILD_ROOT` 밖 파일을 읽지 않는지(임시 폴더에 `before-*` 아닌 파일을 두고 시험).
6. `--dry-run`에서 `apply`·`restore`가 기록만 남기고 `upload`를 부르지 않는지.
7. 토큰 없음·`Host` 다름이 초기화 라우트에서도 401·421로 막히는지.

## 8. 회신에 적어 주실 것

- 바뀐 파일과 줄, 새 라우트 목록, `node --test tools/admin-console/server.test.mjs` 결과(통과 수).
- `초기화` 탭에서 실제로 보이는 문구(범위 이름 셋과 확인 문구) 그대로.
- R2 팩 파일까지 지우는 선택을 넣었는지 여부와, 넣었다면 기본값·확인 방식.
- 초기화 뒤 앱이 받기까지의 실제 시간(엣지 캐시 5분 + 앱 확인 30분)을 한 번 실측했는지 — 못 했으면 「미실측」이라고 적어 주십시오.
- 커밋 해시.

## 점검 회신 (비야, 2026-11-20 18:51)

- **보안 구멍 하나를 막았습니다**: `POST /api/reset/restore`의 `dir`을 본문에서 그대로 받아 폴더를 열면 `../`로 아무 파일이나 읽어 공개 버킷에 올릴 수 있었습니다. 5절에 ⑴ `^reset-…$` 모양 검사 ⑵ `BUILD_ROOT` 안인지 확인 ⑶ `before-*` 두 파일만 읽기 ⑷ 생략 시 메모리의 마지막 초기화만, 를 넣고 `..`·절대경로 시험을 7절에 더했습니다.
- 백업 자리를 실제 코드에 맞췄습니다: `BUILD_ROOT`의 기본값은 `build/admin-console/`(`server.mjs:23`)이고, 기존 폴더 이름도 `announce-<시각>` 꼴입니다 → `build/reset-…` 대신 `build/admin-console/reset-…`으로 적고 「백업 폴더는 `git add` 하지 않는다」를 붙였습니다(지시서의 첫 가정과 다름).
- 인용은 18:4x `origin/main`에서 맞았습니다 — `index.html` 14~18(탭 셋)·22·65·78·90(기록 패널)·96~101(확인 상자), `server.mjs` 265(`exclusive`)·271(routes)·105(`upload`)·286(`baseVersion`)·333~342(파일 먼저·카탈로그 나중·`rangeCheck`)·387·409(Host 421·토큰 401), CI의 `node --test tools/admin-console/server.test.mjs`.
- 고치지 않은 것: 범위 기본값(셋 다 켬)·확인 문구·R2 팩 파일을 지우지 않는 결정·드라이런 정책은 대표가 정한 범위라 그대로 두었습니다.
