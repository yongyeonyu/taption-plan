---
id: 20261119-1828-announcements-ios
created_at: 2026-11-19T18:28+09:00
status: done
finished_at: 2026-11-19T19:40+09:00
commit: 4b957dd9
request_id: ANN1119A01
title: R2 공용 공지 — iOS 앱 수신·표시 연동
from: 비야
basis: 대표 선택 (2026-11-19 18:24 채팅 — 비야가 제시한 다음 작업 후보 중 「2번 R2 공지 앱 연동」 선택. 서버 쪽은 같은 날 R2PUB1119A01에서 끝남)
---

## 할 일

0. `git pull --rebase` 뒤 이 문서를 읽고, `AGENTS.md` 2절대로 `request_id`(`ANN1119A01`)를 `test.md` `## 남은 작업`의 **홈·UI** 영역에 한 줄, `### 요청 상세`에 원인·해결·검증 기준·상태를 먼저 적습니다. 새 ID를 만들지 않습니다.

1. 시작할 때 확인한 현재 상태(2026-11-19 `origin/main` `e0c7e7d`)입니다. 달라졌으면 현재 코드를 기준으로 삼고 그 차이를 회신에 적습니다.

   1-1. **서버(이미 있음, 이번에 고치지 않음)** — `server/trip-relay/src/public.js`, README 「공용 공지·정적 데이터 (R2PUB1119A01)」.
   - `GET /public/announcements` — 인증 없음(공개 경로, `Authorization`을 읽지 않음). R2 `announcements/latest.json`을 **고치지 않고 그대로** 돌려줍니다. 200 + `etag` + `cache-control: public, max-age=300`.
   - `If-None-Match`가 현재 ETag와 같으면 **304**(본문 없음, `etag` 그대로).
   - 바인딩·파일이 없거나 JSON이 깨졌거나 `items`가 배열이 아니면 **200 `{"version":0,"items":[]}` + `cache-control: no-store`**(ETag 없음).
   - `GET`만. 그 밖은 405 + `allow: GET`.
   - 서버는 `startsAt`·`expiresAt`·`minBuild`로 **거르지 않습니다**. 거르는 일이 이번 앱 작업입니다.
   - 공지 예시: `server/trip-relay/test/fixtures/public-announcements.json`(가짜 내용).

   1-2. **공지 JSON 스키마**(README 같은 절의 표가 정본. 필드 이름은 이것 그대로):
   - `version`(정수, `0`은 「아직 없음」), `items`(배열, 최대 50).
   - `items[].id` 필수 `[a-z0-9][a-z0-9._-]{0,63}` · `title` 필수 1~100자 평문 · `body` 필수 1~2000자 평문(HTML·마크다운 금지).
   - `items[].kind` 필수, **`info`·`update`·`warning`·`critical` 넷**이고 이 순서가 곧 심각도입니다. (이 지시서 초안의 「maintenance」 같은 값은 스키마에 없습니다 — 넷만 씁니다. 모르는 값이 오면 `info`로 대접해 **버리지 않습니다**.)
   - `startsAt`·`expiresAt`: ISO 8601 **오프셋 포함**, `expiresAt`은 `null`일 수 있음. 생략 시 제한 없음.
   - `minBuild`·`maxBuild`: 정수, `maxBuild`는 `null`일 수 있음. 생략 시 제한 없음.
   - `link`: 선택, `https://` 300자 이내. `titleByLang`·`bodyByLang`: 선택, `{"en": "…", "ja": "…"}` 같은 사전. **기본 언어는 한국어(`title`·`body`)**.

   1-3. **앱 쪽 붙는 자리**(읽고 고칠 곳):
   - 중계 서버 주소: `Info.plist`의 `TRIP_RELAY_HOST` ← `TaptionPlan/AppSecrets.xcconfig`. 읽는 곳은 `Packages/TaptionAssistant/Sources/TaptionAssistantKit/TripRelay.swift`의 `TripRelay.host`(비었거나 `$(`가 남아 있으면 nil), 주소 만들기는 같은 파일의 `TripRelay.url(_:query:host:)`, 보내기는 `TripRelay.sendResponse(_:session:)`(429 재시도, `TripRelay.$singleAttempt`로 한 번만 시도 가능). **`TripRelay.isAvailable`이 false면 공지 기능은 아무것도 하지 않습니다.**
   - 앱 시작·포그라운드 복귀 훅: `TaptionPlan/UI/MapHomeView+Support.swift`의 `.task { await checkTripRelay() }`(221행)와 `.onChange(of: scenePhase)`(216~220행)가 이미 여행 계획 중계를 이 시점에 부릅니다. 공지 조회도 **같은 두 자리**에서 부릅니다(새 훅을 앱 전역에 만들지 않습니다).
   - 홈 상단 알림 자리: 같은 파일 236행 `.overlay(alignment: .top) { ArrivalCardHost(model:language:) { tripClipboardBanner } }`. `TaptionPlan/UI/ArrivalCardView.swift`의 `MapHomeTopNoticeStack`이 배너 칸과 도착 카드 칸을 세로로 쌓아 겹치지 않게 합니다(RMN1114A23).
   - 배너 모양 본보기: `TaptionPlan/UI/TripClipboardBanner.swift`(표면 `Color.tpSurface`·모서리 16·그림자·`xmark` 44pt 터치 영역·`language.text("한국어", "English")`).
   - 언어: `TaptionPlan/UI/MapHomeLanguage.swift`(한국어/영어만), 번역 언어 코드는 `Packages/TaptionWatchSync/Sources/TaptionWatchSync/UITextPack.swift`의 `UITextPack.activeLanguageCode`와 `AppLanguagePreference`(raw 값 `ja`·`zh-Hans`·`zh-Hant`·`de`·`fr`·`it`·`es`·`pt-BR`·`vi`·`id`·`th`·`hi`).
   - 시험 본보기: `TaptionPlanTests/AssistantRelayTests.swift`(`@testable import TaptionPlan`, `UserDefaults(suiteName:)` 격리), 조건부 요청 본보기: `TaptionPlan/Core/OfflineVectorTileCache.swift`와 `TaptionPlanTests/OfflineVectorTileTests.swift`.
   - 지금 빌드 번호는 `CURRENT_PROJECT_VERSION = 353`입니다(이번에 올리지 않습니다).

2. 구현

   2-1. **새 파일 하나에 모델·필터를 둡니다**(`TaptionPlan/Core/AnnouncementFeed.swift` 같은 이름. 앱 target).
   - `AnnouncementFeed { version: Int, items: [AppAnnouncement] }`, `AppAnnouncement { id, title, body, kind, startsAt?, expiresAt?, minBuild?, maxBuild?, link?, titleByLang?, bodyByLang? }`. 모르는 필드는 무시합니다.
   - 깨진 본문·`items` 없음·`version` 없음은 **예외를 던지지 않고 빈 목록**으로 읽습니다(`version` 기본 0). 한 항목이 깨졌다고 목록 전체를 버리지 않습니다 — 항목 단위로 읽고 깨진 항목만 건너뜁니다.
   - 날짜는 `ISO8601DateFormatter`(`.withInternetDateTime`)로, 밀리초가 붙은 값(`.withFractionalSeconds`)도 읽게 두 갈래로 시도합니다. 못 읽은 날짜는 **그 필드가 없는 것으로** 봅니다(공지를 숨기는 쪽으로 틀리지 않게).
   - 순수 함수 `AnnouncementPolicy` 하나로 거르기·정렬·문구 고르기를 모읍니다. 시험이 이것만 부르게 하고, 네트워크와 섞지 않습니다.
   - 빌드 번호는 `Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")`을 `Int`로 읽습니다. 못 읽으면 빌드 조건은 **거르지 않습니다**(공지를 잘못 숨기는 것보다 낫습니다).

   2-2. **거르기·정렬 규칙**
   - `startsAt`이 있으면 `startsAt <= 지금`, `expiresAt`이 있으면 `지금 <= expiresAt`(양끝 포함). 둘 다 없으면 항상 보임.
   - `minBuild`가 있으면 `minBuild <= 빌드`, `maxBuild`가 있으면 `빌드 <= maxBuild`(양끝 포함).
   - 닫은 `id`는 빼고, 남은 것을 **심각도 내림차순**(`critical` > `warning` > `update` > `info`) → 같으면 `startsAt`이 늦은 것 → 같으면 응답 순서로 정렬합니다.
   - `link`가 `https`가 아니거나 300자를 넘으면 「자세히」만 감추고 제목·본문은 그대로 보여 줍니다.

   2-3. **다국어 고르기** — `titleByLang`·`bodyByLang`에서 지금 앱 언어를 먼저 찾습니다.
   - 지금 언어 키: `UITextPack.activeLanguageCode`가 있으면 그 코드, 없으면 `MapHomeLanguage.current == .korean ? "ko" : "en"`.
   - 찾는 차례: ① 그 코드 그대로(`zh-Hant`·`pt-BR` 포함) ② 하이픈 앞 언어(`zh-Hant`→`zh`, `pt-BR`→`pt`) ③ 없으면 `title`·`body`(한국어). **다른 언어를 끌어다 쓰지 않습니다**(일본어 사용자에게 영어를 보여 주지 않음).
   - 빈 문자열은 없는 것으로 봅니다. 제목·본문은 각각 따로 찾습니다(제목만 번역돼 있어도 그것을 씀).

   2-4. **받기(쿨다운·ETag)** — `AnnouncementService` 하나로 모읍니다(`TripRelay.host`·저장소·보내기를 주입받게 해 시험 가능하게).
   - `TripRelay.isAvailable`이 false면 곧바로 반환(요청 없음).
   - **쿨다운 30분(1800초)**: 마지막 시도 시각을 `UserDefaults`에 두고, 그로부터 30분이 지나지 않았으면 요청하지 않습니다. 시각은 **보내기 전에** 적습니다(멈춘 요청이 반복되지 않게). 포그라운드 복귀가 잦아도 하루 최대 48회(1440분 ÷ 30분)입니다.
   - 요청: `GET {중계 주소}/public/announcements`, 인증 헤더 없음, 쿼리 없음, `timeoutInterval = 8`, `cachePolicy = .reloadIgnoringLocalCacheData`(URLSession 캐시가 우리 ETag·쿨다운 판단을 가리지 않게), 저장한 ETag가 있으면 `If-None-Match`에 **받은 그대로** 넣습니다(R2 `httpEtag`는 따옴표를 포함합니다).
   - 응답:
     - **200** → 본문을 읽어 목록을 갈아 끼우고, 응답의 `ETag` 헤더를 저장합니다. 헤더에 ETag가 없으면(빈 목록 `no-store`인 경우) 저장한 ETag를 **지웁니다**(다음에 본문을 다시 받게).
     - **304** → 지금 목록을 그대로 두고 ETag도 그대로 둡니다. 화면은 바뀌지 않습니다.
     - 그 밖의 상태·타임아웃·연결 실패·깨진 본문 → **조용히 무시**합니다(로그 한 줄은 남겨도 되지만 사용자에게 알리지 않습니다). 지금 목록도 지우지 않습니다.
   - 요청은 한 번만 시도합니다. 재시도·백오프·429 대기를 넣지 않습니다(`TripRelay.$singleAttempt`를 쓰거나 보내기를 직접 감싸서). 공지 때문에 앱이 기다리지 않게 `Task`로 띄우고 화면을 막지 않습니다.
   - 저장 키(모두 `UserDefaults.standard`, 이름은 예시): `announcement.etag`(문자열), `announcement.lastAttemptAt`(1970 기준 초 `Double`), `announcement.dismissedAt`(`[String: Double]` — `id` → 닫은 시각).
   - 목록은 **메모리에만** 둡니다(디스크 본문 캐시를 만들지 않음). 앱을 새로 켜서 첫 조회가 실패하면 아무것도 띄우지 않습니다 — 오프라인에서 지난 공지를 되살리지 않습니다.

   2-5. **닫은 공지 기록**
   - 배너의 X 또는 상세 시트의 「닫기」 → 그 `id`를 `announcement.dismissedAt`에 지금 시각으로 적고, 화면에서 즉시 뺍니다.
   - 정리: ① 서버 응답에 없는 `id`이면서 닫은 지 **90일**이 지난 것 삭제 ② 그래도 200개를 넘으면 오래된 것부터 삭제. 정리는 응답을 받을 때마다 한 번, `UserDefaults` 쓰기는 바뀐 게 있을 때만.
   - 「읽음」을 서버로 보내지 않습니다(공지 조회는 인증·식별자 없이 익명 GET 하나뿐).

   2-6. **화면** — `TaptionPlan/UI/AnnouncementBanner.swift`(새 파일).
   - 자리: `MapHomeView+Support.swift` 236행의 배너 칸 안에서 **공지 배너 → 여행 계획 배너** 순서로 `VStack(spacing: 8)`. 공지가 없으면 `EmptyView`라 자리·간격을 차지하지 않습니다. 도착 카드는 지금처럼 그 아래(`MapHomeTopNoticeStack` 그대로 사용).
   - 배너: `kind`별 아이콘·색 — `info` `info.circle`/`Color.tpAccent`, `update` `sparkles`/`Color.tpAccent`, `warning` `exclamationmark.triangle.fill`/주황, `critical` `exclamationmark.octagon.fill`/빨강. 제목 1줄 + 본문 2줄(`lineLimit(2)`), 탭하면 상세 시트, 오른쪽 X로 닫기. X는 44pt 터치 영역, 접근성 라벨 `language.text("닫기", "Close")`. 배너 전체에 `accessibilityElement(children: .combine)`.
   - 동시에 여러 건: **배너는 1건**(정렬 첫 번째). 탭하면 상세 시트에 표시 중인 공지를 모두 정렬 순서로 보여 주고, 각 항목에 전체 본문·`link`가 있으면 「자세히」(`openURL`, `https`만)·그 항목 닫기 단추. 시트는 `presentationDetents([.medium, .large])` 정도로 가볍게.
   - 문구는 전부 `language.text("한국어 문구", "English text")` 리터럴로 씁니다(시트 제목·닫기·자세히 등 3~6개). 그래야 `Localizable.xcstrings`·`UIText.xcstrings`를 손으로 고칠 일이 없습니다. `Text("…")` 리터럴을 쓰게 되면 `scripts/l10n/extract.py` → `generate.py`를 돌려 키가 빠지지 않게 하고 회신에 적습니다.
   - 앱 시작을 막는 모달·전체 화면 덮개·강제 확인은 만들지 않습니다. `critical`도 배너일 뿐입니다(앱 잠금·튜토리얼·출시 안내 화면 위로 띄우지 않음 — 홈 오버레이라 자연히 그렇습니다).
   - 손대지 않는 곳: `AppShellView`(동결 파일), 잠금 화면·위젯·워치·푸시.

   2-7. **(권장) Debug 미리보기** — `TaptionPlanApp`의 기존 `#if DEBUG` 미리보기 갈래처럼 `-announcementPreview` 인자 하나를 더해, 1-1의 픽스처와 같은 모양의 **가짜 공지 3건**(`info`·`warning`·`critical`, 하나는 `expiresAt` 지난 것)으로 배너·시트를 서버 없이 볼 수 있게 합니다. 실제 사용자·도메인·좌표를 쓰지 않습니다. 넣지 않았다면 회신에 그렇게 적습니다.

3. 시험 — 새 파일 `TaptionPlanTests/AnnouncementTests.swift`, 클래스 이름 `AnnouncementTests`(파일명으로 클래스명을 추측하지 말고 선언을 확인, `-only-testing`이 틀리면 0건 초록이 됩니다).
   1. 픽스처 디코딩: 1-1의 예시 JSON 문자열 그대로 → `version == 3`, 항목 2, `maxBuild: null`·`link`·`titleByLang`이 읽히고 빠진 필드는 nil. 모르는 필드가 있어도 통과.
   2. 깨진 본문/`items` 없음/항목 하나 깨짐 → 빈 목록 또는 그 항목만 빠진 목록, 던지지 않음.
   3. 기간: `startsAt` 미래 제외, `expiresAt` 지난 것 제외, `startsAt == 지금`·`expiresAt == 지금` 표시(양끝 포함), 둘 다 없으면 표시.
   4. 빌드: `minBuild`보다 낮은 앱 제외, `maxBuild`보다 높은 앱 제외, 경계 포함, `null`·없음은 제한 없음, `CFBundleVersion`을 못 읽으면 거르지 않음.
   5. 다국어: `en` 있으면 영어, 없으면 `title`/`body`, `ja` 요청에 `ja` 값, `zh-Hant` 요청에 `zh-Hant` 없고 `zh` 있으면 `zh`, `ko`는 `title` 그대로, 빈 문자열은 없는 것으로.
   6. 닫은 공지: 닫은 `id`는 빠지고 다른 공지는 남음, 90일 지난 닫음 기록이 정리됨, 200개 상한.
   7. 정렬: 심각도 → `startsAt` 순.
   8. 쿨다운: 마지막 시도 29분 뒤 요청 0회, 31분 뒤 1회, 304도 시도 시각을 갱신.
   9. ETag: 첫 200에서 `etag` 저장, 다음 요청에 `If-None-Match`가 그 값, 304면 목록 유지, ETag 없는 200이면 저장값 삭제.
   10. 실패: 연결 오류·500·깨진 JSON에서 목록이 그대로이고 던지지 않음.
   11. 빈 목록 `{"version":0,"items":[]}` → 표시 0건(화면에 아무것도 없음).
   - 보내기는 가짜 전송(요청 캡처 + 정해진 응답)으로 바꿔 끼웁니다. `UserDefaults(suiteName:)` 격리와 `addTeardownBlock` 정리를 `AssistantRelayTests`처럼 합니다.
   - 검증 명령(빌드 잠금 `/tmp/taptionplan-xcodebuild.lock` 안에서, derived data `"/Volumes/TaptionPlanBuild/dd/ANN1119A01"`):
     ```sh
     xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan \
       -configuration Debug -destination 'generic/platform=iOS' \
       -derivedDataPath "/Volumes/TaptionPlanBuild/dd/ANN1119A01" -skipPackagePluginValidation \
       COMPILER_INDEX_STORE_ENABLE=NO \
       OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'

     xcodebuild test -project TaptionPlan.xcodeproj -scheme TaptionPlan \
       -configuration Debug -destination "platform=iOS Simulator,id=99AC6F35-6B50-4741-A11D-1A46E1F7F4BD" \
       -derivedDataPath "/Volumes/TaptionPlanBuild/dd/ANN1119A01" \
       -parallel-testing-enabled NO \
       -resultBundlePath "build/validation/ANN1119A01/app-tests.xcresult" \
       -only-testing:TaptionPlanTests
     ```
     전체 단위 시험의 **실행·통과·실패·건너뜀**을 `xcrun xcresulttool get test-results tests --path …`로 읽어 그대로 적습니다(돌리지 않은 것은 「확인 안 함」). 새 시험 클래스만 먼저 돌려 실패를 빨리 잡아도 됩니다.
   - 구조 점검: `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json` 통과. 동결 파일(`docs/architecture-baseline.json`의 `frozen_files` 5개 — `AppShellView.swift` 포함)에 기능을 더하지 않습니다.
   - 다국어: 새 문구를 리터럴 `language.text`로만 썼으면 `Localizable.xcstrings`에 새 키가 없어야 합니다. 확인하려면 `python3 scripts/l10n/extract.py`를 돌려 `source.json`에 늘어난 문구 수를 적고, 12개 언어 번역 파일에 그 문구가 없어 `check.py`가 실패하면 **실패로 묶지 말고** 「번역 대기 n건」으로 적습니다(`generate.py`는 메인 세션 몫). `UIText.xcstrings`·`Localizable.xcstrings`를 손으로 고치지 않습니다.

4. `test.md` — `ANN1119A01` 한 줄과 상세를 채우고, 상태는 「코드·시험 끝, 대표 몫: 공지 업로드 뒤 실기기 확인」으로. `## 실기기 확인 목록`의 **아이폰 11 Pro** 표에 한 줄 넣습니다: 「공지 1건 업로드 뒤 앱 실행 → 홈 위쪽 배너 표시 / X로 닫기 → 사라짐 / 앱 종료·재실행 → 다시 뜨지 않음」. 서버 업로드가 아직이라 **지금은 확인 불가**임을 적습니다.

5. `pickle-bridge/README.md` 4절 회신 형식대로 `## 클로드 코드 회신`을 적고 `status: done`·`finished_at`·`commit`을 채워 `git mv`로 `done/`에 옮겨 커밋·푸시합니다(작업 커밋과 문서 이동 커밋 분리, 경로 지정 커밋).

## 확인 기준

- 앱 시작·포그라운드 복귀에서 `TripRelay.isAvailable`이면 공지를 1회 확인하고, 30분 쿨다운 안이면 요청하지 않는다(시험으로 고정, 전송 횟수로 확인).
- `startsAt`/`expiresAt`·`minBuild`/`maxBuild`·닫은 `id`·언어 대체가 시험으로 고정되고, `Info.plist`의 빌드 번호를 읽어 쓴다.
- 200·304·빈 목록·타임아웃·500·깨진 JSON 어느 경우에도 앱이 멈추거나 알림을 띄우지 않고, 모달·강제 확인이 없다.
- 표시할 공지가 0건이면 홈 위쪽에 아무 UI도, 어떤 간격도 생기지 않는다.
- `xcodebuild` Debug 빌드 성공, `TaptionPlanTests` 실행·통과·실패·건너뜀 수치가 회신에 있다. 새 시험이 실제로 돌았는지 `xcresulttool`로 확인한다(0건 초록 금지).
- 구조 점검 통과, 동결 파일 무변경.
- 다국어: 새 문구가 모두 `language.text` 리터럴이고 `Localizable.xcstrings`·`UIText.xcstrings`를 손으로 고치지 않았다(늘어난 문구 수·번역 대기 수를 적음).
- 서버 코드·배포·R2 업로드·빌드 번호·TestFlight를 건드리지 않았다.

## 하지 말 것

- `server/trip-relay` 코드·시험·README 수정, R2 업로드·버킷 생성·배포(`AGENTS.md` 12절: 서버 배포는 지시서에 적혀 있어도 대표 몫).
- POI 팩·온디바이스 ML 모델 연동(별도 후속 요청), 공지에 딸린 그림 표시.
- 빌드 번호 올리기, TestFlight, 앱스토어 메타데이터·개인정보처리방침 문구 변경.
- 푸시 알림·잠금 화면·위젯·워치로 공지 확장, 읽음/노출 지표 수집·전송.
- 공지 요청에 `Authorization`·사용자 식별자·쿼리·좌표를 싣는 것(공개 경로, 익명 GET 하나).
- `AppShellView.swift` 등 동결 파일 수정, `MapHomeView` 본 파일에 저장 속성 늘리기(새 상태는 새 파일·extension으로).
- 다른 세션의 미커밋 변경(`TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`) 건드리기·커밋에 넣기.
- 지시서·회신·시험·코드 주석에 실제 중계 서버 주소·계정·실제 좌표·실제 사용자 이름 쓰기(저장소는 공개입니다, `AGENTS.md` 8절). 시험 데이터는 픽스처처럼 가짜로.

## 참고

- `pickle-bridge/README.md`, `AGENTS.md` 2·5·8·12절, `DEVELOPMENT.md` 「검증 명령」.
- 서버: `server/trip-relay/src/public.js`, `server/trip-relay/README.md` 「공용 공지·정적 데이터 (R2PUB1119A01)」, `server/trip-relay/test/fixtures/public-announcements.json`.
- 앱: `Packages/TaptionAssistant/Sources/TaptionAssistantKit/TripRelay.swift`, `TaptionPlan/UI/MapHomeView+Support.swift`(216~221·236행), `TaptionPlan/UI/ArrivalCardView.swift`(`MapHomeTopNoticeStack`), `TaptionPlan/UI/TripClipboardBanner.swift`, `TaptionPlan/UI/MapHomeLanguage.swift`, `Packages/TaptionWatchSync/Sources/TaptionWatchSync/UITextPack.swift`, `TaptionPlan/Core/OfflineVectorTileCache.swift`(조건부 요청 본보기).
- 기록: `test.md`의 `R2PUB1119A01`(서버·남은 대표 몫), `TRP1110A04`(중계 주소·비밀값 없는 공개 GET 선례).
- 이 요청은 **앱 수신·거르기·표시·닫기·시험**까지입니다. 공지 관리 화면(앱에서 쓰기), 여러 기기 읽음 동기화, POI 팩·모델 내려받기는 다음 요청입니다.

## 클로드 코드 회신

- 처리: 완료(전체 단위 시험에 이번 변경과 무관한 실패 1건 남음, 아래 참고)
- 요청 ID: ANN1119A01 (`test.md` 홈·UI 줄·요청 상세·실기기 확인 목록·검증 기록)
- 시작·끝: 2026-11-19 18:35 ~ 19:40 (KST)
- 커밋: `4b957dd9` 작업, 문서 이동은 `[비야 브리지] 20261119-1828-announcements-ios` 한 건. 시작 때 확인한 `origin/main`은 `0fd95aa2`(지시서의 `e0c7e7d` 이후)
- 바꾼 파일: `TaptionPlan/Core/AnnouncementFeed.swift`(새: 모델·거르기·정렬·언어 고르기·`AnnouncementService`), `TaptionPlan/UI/AnnouncementBanner.swift`(새: 배너·시트·`homeTopNotices`), `TaptionPlan/UI/MapHomeView+Support.swift`(기존 두 자리에서 `refresh()`·알림 칸 교체), `TaptionPlanTests/AnnouncementTests.swift`(새 14건), `TaptionPlanTests/TimeScaleTests.swift`(17→18 오래된 기대값), `TaptionPlan.xcodeproj/project.pbxproj`(새 파일 3개 등록), `test.md`. 서버·빌드 번호·동결 파일·`MapHomeView` 본 파일 저장 속성은 건드리지 않음
- 구현 요점: `TripRelay.isAvailable`이 아니면(주소 없음) 요청 없음, 30분 쿨다운(시도 시각을 보내기 전에 적음), `If-None-Match`는 받은 ETag 그대로, 200이면 목록 교체·ETag 없는 200이면 저장값 삭제, 304면 유지, 그 밖은 조용히 무시, 한 번만 시도(`singleAttempt`)·8초 제한·인증·쿼리 없음, 목록은 메모리에만, 닫은 id는 90일/200개 정리, 배너는 가장 급한 1건·시트에 전체, 모달 없음, 공지 0건이면 자리·간격 없음
- 검증: 새 `AnnouncementTests` 14건 통과·실패 0. 구조 점검 통과. 전체 `TaptionPlanTests` 2,947건 실행·건너뜀 26·실패 2(xcresult 통과 3,118) — 실패 `MapHomeStartupCameraTests`는 ICN1119A06 이후 직접 추가 18개인데 기대값이 17이던 것이라 18로 고쳐 단독 통과. 남은 실패 `AssistantAppControlTests.testAskUserStoresTheQuestionAnswersUploadAndUndoWithdrawsOnlyUnanswered`는 이번 변경과 무관한 시간 의존입니다: 시험이 질문을 11-12 시각으로 만드는데 `AITaskQueue.lifetime`이 7일이라 오늘부터 질문이 만료돼 「duplicate」가 안 나옴(손대지 않음, 다음 요청 후보). 시험 실행기가 「hung before establishing connection」으로 0건이 되어 시뮬레이터를 껐다 켜 다시 돌림(`hung-*.log` 보관). 서버 시험·실제 서버 호출·실기기·화면 눈 확인은 안 함
- 알아 둘 것(지시서에 없던 결함 1건): 서버 스키마 예의 `2026-11-25T09:00+09:00`(초 없는 ISO 8601)를 `ISO8601DateFormatter`가 못 읽어 기간 조건이 무시될 뻔했습니다. 시험이 잡아 초 없는 형식도 읽게 고쳤습니다. 서버는 이 형식을 그대로 통과시키므로 공지를 올릴 때 초를 넣든 빼든 앱은 읽습니다
- 남은 것·확인 필요: ① 번역 대기 4문구 × 12개 언어(`공지`·`새 공지가 없습니다`·`이 공지 닫기`·`자세히`, `check.py` 48건 누락, `generate.py`는 메인 세션 몫, 생성물은 되돌려 둠) ② R2 공지 업로드(R2PUB1119A01 대표 몫) 뒤 아이폰 11 Pro 확인 — `test.md` 실기기 확인 목록 ANN1119A01 줄(지금은 확인 불가) ③ Debug `-announcementPreview`로 가짜 공지 3건을 서버 없이 볼 수 있게 넣었으나 화면은 눈으로 보지 못함
