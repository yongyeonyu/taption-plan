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
- **API 키**(KEY1121A01): 아래 「API 키 관리」 참고.
- **설정**: 중계 서버 호스트, R2 버킷, `wrangler.local.toml` 경로. 처음에는 `TaptionPlan/AppSecrets.local.xcconfig`의 `TRIP_RELAY_HOST`와 `server/trip-relay/wrangler.toml`의 버킷을 읽고, 저장하면 `tools/admin-console/config.local.json`(git 제외)에 둡니다.

## 바깥으로 열리지 않게
- `127.0.0.1`에만 묶고, `Host` 머리글이 `127.0.0.1:<포트>`·`localhost:<포트>`가 아니면 421(DNS 리바인딩 차단).
- 로그인 대신 실행마다 새로 만드는 토큰. 페이지는 `?t=` 토큰이 맞아야 열리고, API는 `X-Admin-Token` 머리글이 맞아야 답합니다. POST는 JSON만 받아 다른 사이트의 폼 전송을 막고, CORS에는 답하지 않습니다.
- 공지·팩 올리기는 이 맥에 로그인된 `wrangler`(`npx wrangler r2 object put … --remote`)를 그대로 부릅니다.
- API 키 값은 저장소 밖 파일에만 두고, 화면·API·기록에는 원문을 내보내지 않습니다(아래).

## API 키 관리 (KEY1121A01)
`API 키` 탭에서 앱과 중계 서버가 쓰는 키를 넷으로 나눠 보여 줍니다. 목록은 `tools/admin-console/keys.mjs`의 `KEY_CATALOG`입니다.

| 묶음 | 키 |
|---|---|
| 서버 외부 API 키(10) | `ICN_API_KEY`·`KAC_API_KEY`(항공편), `EX_API_KEY`(고속도로 요금), `TAGO_SERVICE_KEY`(버스), `KAKAO_REST_API_KEY`(장소 검색), `GOOGLE_PLACES_KEY`·`MAPILLARY_TOKEN`·`TOUR_API_KEY`·`UNSPLASH_ACCESS_KEY`·`PEXELS_API_KEY`(사진) |
| 서버 내부 시크릿(8) | `APNS_KEY_P8`·`APNS_KEY_ID`·`APNS_TEAM_ID`·`APNS_TOPIC`(푸시), `PIN_PEPPER`, `CLASSIFIER_ADMIN_TOKEN`, `SHARED_RULES_ADMIN_TOKEN`, `SHARED_RULES_PUBLIC_KEY` |
| iOS 앱 키(2) | `KAKAO_NATIVE_APP_KEY`(카카오 지도), `POSTHOG_API_KEY`(진단 업로드) |
| 연동 예정 | `ALGOLIA_APP_ID`·`ALGOLIA_WRITE_KEY`(ARCH1120A01 2-1단계) + 「칸 추가」로 직접 넣는 칸(예: AWS) |

- **저장 위치**: `~/.bokki-admin-console/keys.json`(저장소 밖, 폴더 700·파일 600, 임시 파일에 쓰고 바꿔 끼움). 작업용 사본에서 실행해도 같은 파일입니다. 지우면 이 맥에 넣어 둔 키가 모두 사라집니다.
- **입력·교체·삭제**: 칸에 붙여 넣고 「저장/교체」. 앞뒤 공백은 지우고, 공백·줄바꿈이 섞인 값은 받지 않습니다(`APNS_KEY_P8`만 `.p8` 내용 전체를 여러 줄로). 화면에는 `••••` + 끝 4자리만 보이고(12자 미만은 끝도 숨김) 원문은 다시 내려오지 않습니다. 「삭제」는 이 맥에 저장한 값만 지우고 만료일·메모는 남깁니다.
- **서버·앱 반영은 자동으로 하지 않습니다.** 각 키의 「반영 방법」에 명령만 보여 줍니다(시크릿을 넣으면 Worker가 새 버전이 되므로 대표 승인 뒤에):
  ```sh
  node tools/admin-console/server.mjs --print-key ICN_API_KEY | (cd server/trip-relay && npx wrangler secret put ICN_API_KEY --config wrangler.local.toml)
  ```
  `--print-key`는 파이프로 넘길 때만 값을 내보내고 터미널 화면에는 찍지 않습니다. 앱 키는 `TaptionPlan/AppSecrets.local.xcconfig`에 직접 적고 다시 빌드합니다(화면에 xcconfig 값이 저장한 값과 같은지/다른지/비었는지만 표시).
- **서버에 들어 있는지**: 「서버 시크릿 이름 읽기」가 `npx wrangler secret list`(이름만, 값 없음)를 불러 키마다 「서버: 들어 있음/없음」을 표시합니다. 읽기만 하고 넣지 않습니다. 연습 모드에서는 명령만 기록합니다.
- **사용량**: 지금 서버는 쓴 수를 밖으로 내보내지 않고, 공급자 사용량 API도 연결하지 않았습니다. 그래서 코드·README에 적힌 한도(예: 항공편 서버 하루 400회, 카카오 검색 키마다 하루 500회, 구글 하루 30건)만 「한도」로 쓰고, 오늘 쓴 수는 「확인 불가」와 이유·확인하는 곳(공급자 화면)을 적습니다.
- **만료일**: 날짜(그날 끝까지 유효)와 갱신 주기 메모를 키마다 저장합니다. 만료됨·7일 이내는 빨강, 30일 이내는 주황, 그 밖은 초록입니다. 만료일을 자동으로 알려 주는 공급자는 없어 직접 적습니다(공공데이터포털 키는 활용신청 현황의 활용기간).
- **조심**: `PIN_PEPPER`는 서버 값을 바꾸면 모든 사용자의 PIN이 맞지 않게 됩니다. 기록용으로만 저장하고 교체 명령은 실행하지 마세요.

## 시험
```sh
node --test tools/admin-console/server.test.mjs
```
가짜 서버 응답과 연습 모드로 공지 올리기·팩 묶기·올리기·내리기, 토큰·Host·JSON 검사를 확인합니다. 실제 R2 업로드는 시험하지 않습니다. API 키 시험은 가짜 값과 임시 파일(`ADMIN_CONSOLE_KEYS`)만 쓰고, 응답·기록에 원문이 없는지·파일 권한 600·만료 색 구분·서버 소스의 `env.*` 키가 목록에 다 있는지를 봅니다.
