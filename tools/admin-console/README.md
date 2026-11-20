# BOKKI 운영 페이지 (ADM1120A01)

이 맥에서만 여는 작은 웹 페이지입니다. 앱 사용자 모두에게 보이는 **공지**와 **시즌 팩**(`.bpack` + 카탈로그)을 R2 공용 버킷에 올리고 내립니다.

```sh
node tools/admin-console/server.mjs             # 실제로 올림
node tools/admin-console/server.mjs --dry-run   # 연습: 명령을 기록만 하고 올리지 않음
```

작업용 사본(worktree)에서 실행해도 서버 주소·wrangler 설정은 원래 저장소의 로컬 파일에서 읽습니다. 실행하면 `http://127.0.0.1:8742/?t=<토큰>` 주소를 터미널에 찍고 브라우저를 엽니다. 끄려면 Ctrl+C. 의존 패키지는 없습니다(Node 20 이상, 팩 묶기에 `python3`).

## 할 수 있는 것
- **공지**: 지금 올라간 공지(`GET /public/announcements`)를 보고, 새로 쓰거나 고치거나 내립니다. 「미리보기」로 검사를 통과해야 「서버에 올리기」가 켜집니다. 검사·합치기 규칙은 `server/trip-relay/scripts/announce.mjs`와 같고, 그 사이 서버 공지가 바뀌었으면(version이 다르면) 올리지 않습니다.
- **시즌 팩**: 번들 시드 폴더(`Packages/SeasonPackKit/Sources/SeasonPackKit/Resources/seed/<id>/<version>/`)를 `scripts/season-pack/build_bpack.py`로 묶어, 서버 카탈로그에 합친 결과를 보여 줍니다. 올리면 **파일을 먼저, 카탈로그를 나중에** 올리고 `Range` 이어받기(206)를 확인합니다. 서버에 같은 버전 이상이 있으면 묶지 않습니다(`manifest.json`의 `version`을 올리세요). 「카탈로그에서 내리기」는 카탈로그 항목만 뺍니다.
- **공개 기간**: 서버 카탈로그의 팩마다 「운영 기간에만 공개」를 고르고 기간 칸(시작~끝, 이 맥 시간대)을 여러 개 넣은 뒤 「기간 배포」를 누르면 카탈로그만 고쳐 올립니다. 앱은 그 기간에만 팩을 켜고(같은 버전은 다시 받지 않음), 기간이 끝나면 꺼집니다. 「매니페스트 기간 그대로」는 칸을 지워 매년 기간(예: 12/19~12/30)으로 돌아갑니다. 새 버전을 올릴 때도 같은 편집기로 기간을 정해 「묶어서 미리보기 → 업그레이드 배포」를 누르면 됩니다(기기는 옛 버전을 지우고 새로 받음).
- **초기화**: 베타 기간용. `초기화` 탭에서 공지 비우기·팩 카탈로그 비우기·기간 지우기를 골라(기본 셋 다) 「미리보기」로 전/후 JSON을 보고, 확인 칸에 `초기화`를 입력해 실행합니다. 실행 직전 공지·카탈로그는 `build/admin-console/reset-<시각>/before-*.json`에 백업(git 제외)되고, 「방금 초기화 되돌리기」가 그 백업을 그대로 다시 올립니다. 미리보기 뒤 서버가 바뀌었으면(409) 올리지 않습니다. R2의 팩 파일은 지우지 않습니다. 기기에 이미 받은 팩·읽음 표시는 앱의 설정 › 모든 데이터 삭제로 지웁니다(콘솔은 기기에 닿지 못합니다).
- **설정**: 중계 서버 호스트, R2 버킷, `wrangler.local.toml` 경로. 처음에는 `TaptionPlan/AppSecrets.local.xcconfig`의 `TRIP_RELAY_HOST`와 `server/trip-relay/wrangler.toml`의 버킷을 읽고, 저장하면 `tools/admin-console/config.local.json`(git 제외)에 둡니다.

## 바깥으로 열리지 않게
- `127.0.0.1`에만 묶고, `Host` 머리글이 `127.0.0.1:<포트>`·`localhost:<포트>`가 아니면 421(DNS 리바인딩 차단).
- 로그인 대신 실행마다 새로 만드는 토큰. 페이지는 `?t=` 토큰이 맞아야 열리고, API는 `X-Admin-Token` 머리글이 맞아야 답합니다. POST는 JSON만 받아 다른 사이트의 폼 전송을 막고, CORS에는 답하지 않습니다.
- 비밀값은 다루지 않습니다. 올리기는 이 맥에 로그인된 `wrangler`(`npx wrangler r2 object put … --remote`)를 그대로 부릅니다.

## 시험
```sh
node --test tools/admin-console/server.test.mjs
```
가짜 서버 응답과 연습 모드로 공지 올리기·팩 묶기·올리기·내리기, 토큰·Host·JSON 검사를 확인합니다. 실제 R2 업로드는 시험하지 않습니다.
