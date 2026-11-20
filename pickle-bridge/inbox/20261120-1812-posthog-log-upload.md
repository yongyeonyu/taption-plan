---
id: 20261120-1812-posthog-log-upload
created_at: 2026-11-20T18:12+09:00
status: pending
request_id: PHG1120A01
title: 데이터 보호의 진단 업로드를 iCloud → PostHog로 (로그·어제오늘 원본 GPS 포함, 개발자에게 보내기 삭제)
from: 비야
basis: 대표 직접 지시 (2026-11-20 18:0x 통화) — 「일단 디버깅 단계니까. 일단 지금 데이터 보호 안에 아이클라우드 업로드를 이름을 포스트호그 로그 업로드로 바꾸고, 그 밑에 로그 업로드를 하면 로그를 포스트호그로 보내고, 어제·오늘 원본 업로드를 하면 그 GPS까지 포함해서 올리는 걸로 바꿔주고, 그 밑에 개발자에게 보내기 메뉴는 아예 삭제. 베타 테스터도 포스트호그로 보내면 내가 받을 수 있잖아.」 / 같은 통화에서 PostHog 접속 정보(호스트·프로젝트 API 키)를 대표가 직접 전달
---

## 0. 한 줄 요약

「데이터와 개인정보(데이터 보호)」 화면의 **iCloud 로그 업로드** 카드를 **포스트호그 로그 업로드**로 바꾸고, 두 버튼을 iCloud Drive 대신 **PostHog**(HTTP capture, SDK 추가 없음)로 보내게 한다. **어제·오늘 원본 업로드는 지금 iCloud에 쓰던 GPS·모션·기압 원본을 그대로** 보내고, 그 아래 **「개발자에게 보내기」 메뉴는 삭제**한다.

디버깅 단계라 베타 테스터도 같은 빌드에서 이 두 버튼으로 자기 진단을 대표의 PostHog 프로젝트로 보낼 수 있게 하는 것이 목적이다.

**처리 순서(브리지 공통, 2026-11-20 점검)**: 파일 이름 순서로 `1805 RTA1120A01` 다음 네 번째입니다. 이 문서는 `MapHomeSettingsSheets.swift`의 데이터 보호 카드 하나와 `PostHogDiagnosticsUploader.swift`(새 파일)만 만지므로, 시작 경로(LAG·BUB)·홈 폴링(RTA)·중계 서버(FLT)와는 파일이 겹치지 않습니다. 다만 **원본 업로드 대상은 `exportTodaySensorRawURL()`이 만드는 자료**라, FLT1120A01이 같은 함수를 고치면(아직 고치지 않음) 둘을 확인한 뒤 합치십시오.

## 1. 합격선 (이것이 되면 끝)

1. 데이터 보호 화면의 카드 제목이 **「포스트호그 로그 업로드」**이고, 설명문에 iCloud Drive·TaptionLogs 언급이 없다.
2. **「로그 업로드」**를 누르면 진단 로그(요약 + iPhone·Watch 로그 + 직전 비정상 종료 상태)가 PostHog에 이벤트로 도착한다. **좌표·원본 센서는 지금처럼 들어가지 않는다**(요약·모드·노선·기기/OS/앱버전·오류 필드까지).
3. **「어제·오늘 원본 업로드」**를 누르면 그 이틀의 센서 원본(**GPS 좌표 포함**, 모션·기압·이동·방문 장소·활동 기록)이 PostHog에 도착한다. 배치로 나뉘어 오고, 화면에 **배치 수·표본 수·용량**이 보인다.
4. 두 버튼 모두 **iCloud Drive에 쓰지 않는다.** 대신 **로컬 사본(.txt.gz / 원본 JSON)은 앱 컨테이너에 남겨** 전송이 실패해도 근거를 잃지 않고, 실패 사유와 **「재시도」**가 화면에 나온다.
5. **「개발자에게 보내기」 메뉴가 완전히 사라진다**(호출부·extension·시트·상태·안내문). 빌드가 통과한다.
6. 키가 없는 빌드에서는 두 버튼이 **비활성**이고 **「PostHog 키가 설정되지 않았습니다」**로 보인다. 키는 앱 코드·커밋되는 파일에 절대 없다.
7. 원본 버튼 위에 **한 줄 고지**가 있고, 처음 누를 때 **1회 동의 확인**을 거친다(「다시 묻지 않기」 선택 가능, 동의 뒤 「다시 묻기」 제공).
8. `PRIVACY.md`가 새 흐름(PostHog로 로그·위치 원본 전송)으로 고쳐지고, `AGENTS.md` 4절 「좌표 예외」에 이 예외가 대표 결정으로 기록된다. **같은 커밋**에 들어간다.

## 2. 지금 저장소에서 확인한 사실 (2026-11-20 18:05, `origin/main` `48423c1a`)

착수할 때 `rg -n`으로 다시 확인하고, 줄이 달라졌으면 회신에 적으십시오.

| 곳 | 지금 있는 것 | 이번에 볼 점 |
|---|---|---|
| `TaptionPlan/UI/MapHomeSettingsSheets.swift:194~209` | `struct MapHomeSecuritySheet`, `@State rawExportStatus`, `@State var developerAttachment`, `@State var developerMailStatus` | 뒤 두 상태는 이 화면 전용 — 삭제 대상 |
| `MapHomeSettingsSheets.swift:288` | `.card(language.text("iCloud 로그 업로드", "iCloud Log Upload"))` | 제목·설명·아이콘 교체 |
| `:289~292` | 설명문 「iPhone·Apple Watch 진단 로그와 직전 비정상 종료 상태를 iCloud Drive의 TaptionLogs에 저장합니다.」 | PostHog 문구로 교체 |
| `:297~311` | 버튼 1 → `model.exportDiagnosticsToICloud()`, 라벨 「로그 업로드」, 아이콘 `icloud.and.arrow.up`, `.disabled(model.isExportingDiagnostics)`, 상태 `model.diagnosticsExportStatus` | 전송 함수 교체, 아이콘 교체 |
| `:316~317` | `model.diagnosticsLatestLogSummary`(iCloud에 마지막으로 저장한 파일 이름·시각) | 의미를 「최근 전송」으로 바꿈 |
| `:319~335` | 버튼 2(주석 `SUB1029A01`) → `exportSensorRawToICloud()`, 라벨 「어제·오늘 원본 업로드」, 아이콘 `location.square` | 전송 함수 교체 + 고지·동의 추가 |
| `:338` | `developerMailButtons` | **삭제** |
| `:803~856` | `extension MapHomeSecuritySheet` — `developerMailButtons`, `developerMailButton(_:subject:source:)` | **삭제**(두 상태와 함께) |
| `TaptionPlan/UX/AppModel+Export.swift:36` | `exportTodaySensorRawURL()` — 어제·오늘 `[TodaySensorRawExport]` JSON을 임시 폴더에 씀. `places`·`actuals` 포함, 일정 제목·기기 이름은 가림(`GOO1106A01`·`WSN1112A02`) | 배치 전송을 위해 **자료 만들기와 파일 쓰기를 나눈다** |
| `AppModel+Export.swift:93` | `diagnosticsPackageURL()` — `TaptionPlanDiagnosticsLogPackageBuilder`로 패키지를 Application Support에 씀(이미 로컬 사본!) | 로컬 사본 단계로 재사용 |
| `AppModel+Export.swift:103` | `exportSensorRawToICloud()` — `exportTodaySensorRawURL` → `TaptionPlanDiagnosticsICloudExporter().export(url, updatesLatest: false)` | PostHog 전송으로 교체 |
| `AppModel+Export.swift:115~191` | `exportDiagnosticsToICloud()` — `logger.beginOperation("diagnostics_export", destination: icloud_drive)` → 패키지 → iCloud → UserDefaults(`diagnosticsLatestFileKey`)·상태 키 | PostHog 전송으로 교체, 진단 기록(`diagnostics_export_*`) 이벤트는 이름·필드를 새 흐름에 맞게 |
| `AppModel+Export.swift:193~244` | `diagnosticsSummary` — `app_version`·`build`·`os`·`device_model`·개수들·`cloud_status`·widget/watch skip 수 등 | **그대로 이벤트 속성으로** 쓴다(좌표 없음) |
| `TaptionPlan/UX/AppModel.swift:185~188` | `isExportingDiagnostics`, `diagnosticsExportStatusKey`, `diagnosticsExportStatus` | 원본 업로드용 상태를 따로 둔다 |
| `AppModel.swift:284~` | `diagnosticsLatestLogSummary`(UserDefaults의 파일 이름·시각) | 문구를 「최근 전송」으로 |
| `TaptionPlan/Core/DiagnosticsLogSupport.swift:6` | `TaptionLogGzip.compress` (gzip) | **그대로 재사용**(요청 본문 압축) |
| `DiagnosticsLogSupport.swift:264~267` | `TaptionPlanDiagnosticsTravelSummary` 주석 「Coordinates and raw sensor samples stay out of the export, while mode and subway-route names make a transit inference auditable」 | 로그 쪽 제외 규칙의 근거 — **유지** |
| `DiagnosticsLogSupport.swift:695~791` | `TaptionPlanDiagnosticsLogPackageBuilder.makePackage(summary:iphoneLog:watchLog:)` — 요약+로그를 `.txt.gz`로 Application Support `TaptionPlan/Diagnostics/Packages`에 쓰고 최근 6개만 남김. `TaptionPlanDiagnosticsLogPolicy.redactingPersonalHealthFields`·`TaptionWatchDiagnosticsPrivacy.redacted` 적용 | 로컬 사본 + **전송할 평문 텍스트**를 함께 돌려주게 바꾼다(아래 5절) |
| `DiagnosticsLogSupport.swift:812~`(매니페스트)·`:826~`(내보내기) | `TaptionDiagnosticsLatestLogManifest`, `TaptionPlanDiagnosticsICloudExporter`(`updatesLatest` false면 `latest.json` 유지) | **지우지 않는다**(7절) |
| `TaptionPlan/UI/MapHomeDeveloperMail.swift:11·62·69` | `MapHomeZipArchive`, `MapHomeDeveloperAttachment`, `MapHomeDeveloperMailSheet` | **다른 화면이 쓴다** — `MapHomePlaceBookTools.swift:578·644·676`(장소 요청 메일). 파일은 그대로 |
| `TaptionPlan/UI/MapHomeView.swift:627·657` | 벤치 흐름(`-autoBenchMapPan`, `-autoStartDayPlayback`) 끝에서 `await model.exportDiagnosticsToICloud()` — 주석은 「로그 패키지를 만든다(USB로 받아 본다)」 | **네트워크 없이 로컬 패키지만** 남기게 바꾼다(무인 실행이 PostHog로 나가면 안 됨) |
| `TaptionPlan/AppSecrets.xcconfig` | 공개 템플릿. 값은 여기, 비밀값은 빈 칸으로 두고 맨 아래 `#include? "AppSecrets.local.xcconfig"`. `.gitignore`에 `*.local.xcconfig` | 새 키 두 개를 **include 줄 위에** 둔다(아래 함정) |
| `TaptionPlan/Info.plist:5·120·164` | `AIR_QUALITY_PROXY_HOST`·`TRIP_RELAY_HOST`·`WIKIMEDIA_CONTACT`를 `$(VAR)`로 받는 관례 | 같은 방식으로 두 키를 넣는다 |
| `TaptionPlan/PrivacyInfo.xcprivacy:10·22` | 수집 데이터: 정밀 위치·대략 위치, 목적 **앱 기능**만 | 위치 목적에 **분석**을 더한다 |
| `PRIVACY.md:39·40` | 「iCloud Drive에 저장」·「개발자에게 보내기 … support@… 메일」 두 줄 | 이 두 줄을 새 흐름으로 다시 쓴다 |
| `AGENTS.md` 3절·4절 | 「좌표는 AI·서버·분석으로 보내지 않습니다. 예외는 4절 「좌표 예외」에 적힌 것뿐」 (현재 네 가지: 동행 위치·장소 사진·버스 정류장·통행료) | **다섯 번째 예외**가 필요하다(6절) |
| `TaptionPlanTests/DiagnosticsLogSupportTests.swift:316·398·403`, `FeatureEngineTests+Watch.swift:2056`, `FeatureEngineTests+Persistence.swift:1604` | 패키지 빌더·iCloud 내보내기 시험 | **깨뜨리지 않는다**(시그니처 유지) |
| `TaptionPlan/UIText.xcstrings:19177·216990·319246` | 「iCloud 로그 업로드」·「개발자에게 보내기」·「어제·오늘 원본 업로드」 문구 | `scripts/l10n/extract.py` → `check.py`(12개 언어). `generate.py`는 메인 세션 몫 |

- 앱에는 **PostHog가 없다**(`PostHog`·`phc_` 0건). 이번에 새로 붙이는 작업이다.
- 기존 함정(`test_ARCHIVE.md` KMP1113A01): `AppSecrets.xcconfig`에서 **빈 값이 `#include?`보다 아래에 있으면** 로컬 파일 값을 덮어 빌드된 `Info.plist`가 0자가 된다. 새 키는 반드시 include 줄 **위**에 둔다.

## 3. 화면 명세 (데이터 보호 › 이 카드)

기존 `card(...)` 틀·글꼴·색(`Color.tpReferenceBlue`)·`language.text(ko, en)` 관례를 그대로 쓴다.

**① 제목**: `포스트호그 로그 업로드` / `PostHog Log Upload`

**② 설명문**
- ko: `iPhone·Apple Watch 진단 로그와 직전 비정상 종료 상태를 개발자 분석 서비스(PostHog)로 보냅니다. 로그에는 좌표와 원본 센서 값이 들어가지 않습니다.`
- en: `Sends iPhone and Apple Watch diagnostics plus the previous unfinished session to the developer's analytics service (PostHog). Logs carry no coordinates or raw sensor values.`
- iCloud Drive·TaptionLogs 문구는 넣지 않는다.

**③ 버튼 1 — 「로그 업로드」**(라벨 유지)
- 아이콘: `icloud.and.arrow.up` → **`arrow.up.doc`**
- 동작: 4.2절. `isExportingDiagnostics` 동안 비활성, 진행 `전송 중 3/7`.
- 상태 텍스트: 성공 `전송됨 · 이벤트 3 · 214KB` / 실패 `실패 · 429 한도 초과 (…사유)`.
- `model.diagnosticsLatestLogSummary` 자리는 **「최근 전송: 〈시각〉 · 〈파일 이름〉」**으로 쓴다(없으면 `최근 전송 없음` / `No recent upload`). 저장 키(`diagnosticsLatestFileKey`·`diagnosticsLatestSavedAtKey`)는 그대로 재사용한다.
- 실패 시 같은 줄 옆에 **「재시도」**.

**④ 고지 한 줄**(버튼 2 바로 위, 작은 secondary)
- ko: `위치 원본(GPS·모션·기압)이 개발자 분석 서비스 PostHog로 전송됩니다.`
- en: `Raw location data (GPS, motion, pressure) is sent to the developer's analytics service, PostHog.`

**⑤ 버튼 2 — 「어제·오늘 원본 업로드」**(라벨 유지, 아이콘 `location.square` 유지)
- 동작: 4.3절. 누르면 **먼저 동의 확인**:
  - 시트(또는 `confirmationDialog`) 제목 `위치 원본을 보낼까요?` / `Send raw location data?`
  - 본문 `어제·오늘 기록한 GPS 좌표와 센서 원본이 개발자 분석 서비스(PostHog)로 전송됩니다. 집·회사 주변이 드러날 수 있습니다.` / `Yesterday's and today's GPS coordinates and raw sensor samples go to the developer's analytics service (PostHog). They can reveal where home and work are.`
  - 단추 `전송`(destructive 아님)·`취소`, 체크(토글) `다시 묻지 않기`
  - 동의는 `UserDefaults.standard`의 `plan_posthog_raw_upload_consent`(Bool)로 기억한다. 동의 뒤에는 확인 없이 바로 보내고, 카드 아래 작은 글씨 `위치 원본 전송에 동의함 · 다시 묻기`로 되돌릴 수 있다(누르면 플래그 해제).
- 진행·결과 표시: `전송 중 4/9` → `전송됨 · 배치 9 · 표본 2,340 · 1.4MB` / `실패 · 402 한도 (…)` + **「재시도」**.
- 전송 중에는 두 버튼 모두 비활성(동시에 두 흐름이 돌지 않게).

**⑥ 키 없음**
- 두 버튼 비활성 + 상태 `PostHog 키가 설정되지 않았습니다` / `PostHog key is not set`. (버튼을 숨기지 않는다 — 베타 테스터가 이유를 알 수 있게)

**⑦ 삭제**
- `developerMailButtons`(338) 호출, extension(803~856), `developerMailStatus`·`developerAttachment`(208·209), 안내문 「위치 기록이 포함될 수 있어요…」, `MapHomeDeveloperMailSheet`를 이 화면에 붙이던 `.sheet(item:)`까지.

## 4. PostHog 전송 — 연결·이벤트·배치

### 4.1 접속 정보와 키 (코드에 넣지 않는다)

- Host: `https://us.i.posthog.com`
- 엔드포인트: **레거시 `POST /batch/`** (본문 `{api_key, batch:[…]}`, gzip은 `Content-Encoding: gzip`). v1(`/i/v1/analytics/events`)은 이벤트마다 `uuid`·`created_at`·`Authorization: Bearer`가 필요해 이번엔 쓰지 않는다.
- 프로젝트: 조직 `BOKKI Plan` / `Default project`(ID `737239`) — **BOKKI Encoder와 같은 프로젝트**다. 그래서 4.5절의 앱 구분 속성이 필수다.
- 프로젝트 API 키(클라이언트용): **값은 이 문서에 쓰지 않는다**(공개 저장소). 넣는 곳은 git 무시 파일 `TaptionPlan/AppSecrets.local.xcconfig` 하나이고, 대표가 값을 직접 넣거나 클로드 코드 세션에 따로 전달한다.
  - **앱 코드·커밋되는 파일·시험·로그·회신에 넣지 않는다.** 값이 없으면 코드는 끝까지 넣고, 회신에 「키가 아직 없다 — 대표가 `AppSecrets.local.xcconfig`에 넣으면 버튼이 켜진다」를 적는다(실기기 전송 1회만 남는다). **키가 없다고 막힘(`status: blocked`)으로 두지 않는다** — 1-6·3-⑥의 「키 없음」 상태가 바로 그 단계다.
  - 이 저장소의 기존 관례가 Encoder의 `Config/PostHog.xcconfig` + `Config/PostHog.local.xcconfig`와 같은 모양이다(공개 템플릿 + git 무시 로컬 파일). **두 번째 비밀값 체계를 만들지 말고** 이 저장소의 `AppSecrets` 방식을 그대로 쓴다.
- 커밋되는 `TaptionPlan/AppSecrets.xcconfig`에 **include 줄 위**로:
  ```
  // PostHog 진단 업로드(PHG1120A01). 프로젝트 키는 로컬 파일에만 둔다. 비어 있으면 업로드 버튼을 끈다.
  POSTHOG_HOST = us.i.posthog.com
  POSTHOG_API_KEY =
  ```
- `TaptionPlan/Info.plist`에 `POSTHOG_HOST`·`POSTHOG_API_KEY`를 `$(…)`로 넣는다(`AIR_QUALITY_PROXY_HOST`와 같은 자리).
- 읽는 쪽은 `Bundle.main.object(forInfoDictionaryKey:)`로 읽고, **빈 값·`$(`가 남은 값이면 없는 것으로 본다**(`AirQualityContextService.proxyBaseURL`의 처리 방식 참고).
- `TaptionPlan/AppSecrets.local.xcconfig`에 `POSTHOG_API_KEY = phc_…`를 넣고, `git status`에서 그 파일이 **무시 대상으로 보이는지** 확인한다(회신에 키 값은 쓰지 않는다).
- **키를 문서·커밋에 남기지 않는다.** PostHog 프로젝트 키(`phc_…`)는 앱에 박히는 클라이언트 키라 값 자체가 서버 비밀은 아니지만, 공개 저장소에 있으면 누구나 이 프로젝트로 이벤트를 보내 한도·용량을 태울 수 있다. 2026-11-20 18:51 점검에서 이 문서에 적혀 있던 값을 지웠다(이미 커밋된 이력에는 남아 있으므로 **대표가 PostHog에서 키를 회전할지 판단**). 회신에는 「키는 로컬 xcconfig에만 있음」 한 줄만 적는다.

### 4.2 「로그 업로드」 이벤트

- 이벤트 이름 **`plan_diagnostics_log`**
- 전송 본문(요약): 같은 세션의 이벤트를 묶는 `session_id`(UUID, 전송 1회마다 새로), `app`, `source` 넣고 `chunk`/`chunks`, `log_text`.
- `properties`:
  - `$process_person_profile: false`(사람 프로필을 만들지 않는 익명 이벤트)
  - `$insert_id: "<session>-log-<chunk>"` (재전송이 두 번 세지 않게. 효과는 첫 실기기 전송에서 이벤트 수로 확인해 회신)
  - `app: "bokki-plan"`, `source: "diagnostics"`
  - `session_id`, `chunk`, `chunks`, `chunk_bytes`, `sha256`(그 조각의 바이트 해시 — 조립 확인용)
  - `diagnosticsSummary`의 키들을 **이름 그대로** 펼친다(`app_version`·`build`·`os`·`device_model`·`cloud_status` 등) + `travel_mode_counts`·`subway_lines`·`subway_stations`(지금 `TaptionPlanDiagnosticsTravelSummary`가 주는 것)
  - `log_text`: 패키지 평문(아래 5절) 중 **UTF-8 200KB 이하 조각**. 줄 경계에서 자른다(로그는 한 줄에 JSON 하나). 요약 블록은 첫 조각에만 들어간다.
- `distinct_id`: **앱이 만든 랜덤 UUID**(`plan_diagnostics_anon_id`, `UserDefaults.standard`). IDFV·IDFA·기기 이름·계정은 쓰지 않는다.
- `timestamp`: ISO 8601(`ISO8601DateFormatter`).
- **좌표·원본 센서 금지**: 지금 패키지가 쓰는 `TaptionPlanDiagnosticsLogPolicy.redactingPersonalHealthFields`·`TaptionWatchDiagnosticsPrivacy.redacted`를 그대로 통과시킨 텍스트만 보낸다. `SensorReading`·`GeoPoint` JSON을 이 이벤트에 넣지 않는다.
- 요청 묶음: 한 요청에 여러 이벤트를 담아도 되지만 **압축 전 본문 3MB**를 넘기지 않게 나눈다. 요청 본문은 `TaptionLogGzip.compress`로 gzip하고 `Content-Encoding: gzip`.

### 4.3 「어제·오늘 원본 업로드」 이벤트

자료는 지금 `exportTodaySensorRawURL()`이 만드는 `[TodaySensorRawExport]`(어제·오늘 두 덩이: `day`·`isComplete`·`readings`·`travel`·`places`·`actuals`)를 **그대로** 쓴다. 일정 제목·기기 이름 가리기(`GOO1106A01`·`WSN1112A02`)도 그대로.

- **메타 이벤트 `plan_diagnostics_raw_meta`** (한 요청당 하나)
  - `app: "bokki-plan"`, `source: "sensor_raw"`, `session_id`, `days`, `days_complete`, `samples_total`, `batches_total`, `truncated`, `raw_bytes_uncompressed`,
  - `days`별 `travel`·`places`·`actuals`는 **그대로** 싣는다(디버깅 재판정에 필요. 지금 iCloud에 쓰던 것과 같은 내용).
- **배치 이벤트 `plan_diagnostics_raw_batch`** (배치마다 하나)
  - `properties.samples`: 그 배치의 `readings` 배열(지금 JSON 인코딩 그대로의 객체들 — 재생 시험이 읽는 형식 보존)
  - `session_id`, `batch`(0부터), `batches`, `samples`, `day`(그 표본의 날짜), `bytes`
  - `$insert_id: "<session>-raw-<batch>"`, `$process_person_profile: false`
- **자르는 규칙(둘 중 먼저 닿는 쪽)**: 표본 **500개** / 그 배치 JSON **256KB(압축 전)**. 한 이벤트는 1MB를 넘기지 않는다(PostHog는 약 1MB가 넘는 이벤트를 버린다 — `event_too_big`).
- **전체 상한**: 표본이 20,000개를 넘으면 **최근 20,000개만** 보내고 `truncated: true` + 화면에 `최근 20,000개만 전송`을 적는다(한도·전송 시간 보호).
- 요청 묶음: 압축 전 **3MB** 이하로 묶고, 각 요청을 gzip한다. 배치가 많으면 순서대로 여러 요청.
- 진행 표시: `전송 중 <보낸 배치>/<전체>`; 끝나면 `전송됨 · 배치 9 · 표본 2,340 · 1.4MB`(압축 전 기준임을 상태에 적거나 `1.4MB(압축 전)`으로).

### 4.4 응답·실패 처리 (조용히 삼키지 않는다)

- `200` → 성공. 본문 `{"status": "Ok"}` 확인.
- `400·401·413` → **다시 시도해도 같은 결과**이므로 재시도 단추를 숨기고 사유를 그대로 표시(본문이 있으면 300자까지).
- `429` → `한도 초과로 거절됨(429)` + 「나중에 다시」. `402`·`403` → `한도·결제로 거절됨(<코드>)`.
- `5xx`·시간 초과·네트워크 끊김 → `실패 · <사유>` + **「재시도」**(성공한 배치·조각은 건너뛴다, 5절).
- 화면에 넣는 사유는 그대로(감싸지 말 것) — 대표가 응답 코드로 원인을 안다.
- **요청·응답 본문을 진단 로그에 남기지 않는다.** `TaptionPlanDiagnosticsLogger`·`PRFBENCH`·콘솔에 헤더·본문·응답을 찍지 않는다(키가 헤더에서 새고, 원본 배치에는 좌표가 들어 있다). 남길 것은 `이벤트 수·배치 수·바이트·응답 코드·걸린 초`뿐이다.
- **자동·백그라운드 전송 없음**: 이 전송은 버튼을 누를 때만, 앱이 전면일 때만 한다. 재시도도 사용자가 누른다.
- 실패해도 앱이 죽거나 `userFacingError`로 화면을 덮지 않는다(이 카드 안 상태 줄만).

### 4.5 Encoder 이벤트와 섞이지 않게

같은 프로젝트를 BOKKI Encoder(그 앱은 PostHog **SDK + Logs**)와 공유한다. 그래서 모든 이벤트에 `app: "bokki-plan"`, `source: "diagnostics"|"sensor_raw"`를 **반드시** 넣고, 이벤트 이름도 `plan_` 접두사를 쓴다. PostHog에서 `app = bokki-plan`으로 걸러 보면 이 앱 것만 보여야 한다(회신에 그 필터로 확인한 결과를 적는다).

## 5. 로컬 사본과 재시도

1. **먼저 로컬에 쓴다.** 지금 `TaptionPlanDiagnosticsLogPackageBuilder`가 이미 Application Support(`TaptionPlan/Diagnostics/Packages`)에 `.txt.gz`를 쓰고 최근 6개만 남긴다. 이 단계는 그대로 두고, **평문 텍스트도 함께 돌려주게** 바꾼다:
   - `makePackageText(summary:iphoneLog:watchLog:) -> (text: String, fileURL: URL)`를 새로 두고, 기존 `makePackage(...) throws -> URL`은 그 함수를 부르는 얇은 껍데기로 남긴다(**시험 4건이 이 시그니처를 쓴다**).
2. **원본 JSON도 앱 컨테이너에 남긴다**: `Application Support/TaptionPlan/Diagnostics/RawUploads/`에 `Taption-Raw-2Days-<시각>-<8자>.json`, 최근 3개만 유지. 성공해도 지우지 않는다(디버깅 근거).
3. **전송 상태 파일**: `…/Diagnostics/upload-state.json` — 세션 id, 성공한 조각·배치 목록, 마지막 사유·시각. 재시도 때 그 목록을 건너뛴다.
4. 실패 시 로컬 파일이 그대로 남아 있는지가 시험 항목이다(9절 ④).
5. 앱을 껐다 켜도 마지막 결과가 보이게: 마지막 결과 한 줄은 UserDefaults(`plan_posthog_last_result`)에 요약만 남긴다(좌표·키 없음).

## 6. 개인정보 — 고지·동의·문서 (필수)

이 화면은 이제 **베타 테스터의 위치 원본까지 대표의 PostHog 프로젝트로** 보낸다. 코드만 바꾸고 문서를 두면 안 된다.

1. **화면**: 3절 ④⑤의 고지 한 줄 + 첫 1회 동의(+「다시 묻지 않기」, 「다시 묻기」).
2. **`AGENTS.md` 4절 「좌표 예외」에 다섯 번째로 추가**(대표 직접 지시 근거, 2026-11-20):
   > 5. **진단 업로드(2026-11-20, PHG1120A01)**: 사용자가 「데이터 보호 › 포스트호그 로그 업로드」에서 「어제·오늘 원본 업로드」를 **직접 누르고 동의했을 때만**, 그 이틀의 센서 원본(위치 기록, 이동, 활동, Wi-Fi 이름 등)과 방문 장소·이동·활동 기록이 개발자 분석 서비스(PostHog)로 전송됩니다. 자동·백그라운드 전송은 없고, 「로그 업로드」에는 좌표·원본 센서가 들어가지 않습니다. 이 예외도 AI·다른 분석·다른 서비스로 넓히지 않습니다.
   - 브리지 규약 6절이 4절 변경을 되묻도록 되어 있으면, 이 지시서 `basis`의 **대표 지시 원문**을 근거로 위 문구를 그대로 기록하고 회신에 그 사실을 한 줄 적는다(코드 작업은 계속).
3. **`PRIVACY.md`** 39~40행 두 줄을 새 흐름으로 다시 쓴다:
   - 로그: 「사용자가 「데이터 보호 › 포스트호그 로그 업로드」에서 「로그 업로드」를 실행하면 진단 로그가 개발자 분석 서비스(PostHog, 미국)로 전송됩니다. 로그에는 제목·메모 본문·좌표·원시 건강값이 들어가지 않으며, 지하철 노선·역 이름과 기기·OS·앱 버전, 오류 필드가 들어갑니다.」
   - 원본: 「사용자가 「어제·오늘 원본 업로드」를 직접 누르고 동의하면, 그 이틀의 센서 원본(위치 기록, 이동, 활동, Wi-Fi 이름 등)과 방문 장소·이동·활동 기록이 같은 서비스로 전송됩니다. 자동으로 보내지 않으며, 받은 자료는 문제 확인에만 쓰고 삭제를 원하면 support@bokkiyaw.com으로 요청할 수 있습니다.」
   - iCloud Drive 저장·개발자 메일 문구는 지운다(다른 곳에서 iCloud로 내보내는 기능이 남아 있으면 그 문구만 정확히 남긴다 — 7절 확인).
4. **`TaptionPlan/PrivacyInfo.xcprivacy`**: 정밀 위치의 목적에 `NSPrivacyCollectedDataTypePurposeAnalytics`를 더한다(대략 위치는 그대로). 앱이 진단 데이터를 수집한다는 항목(`NSPrivacyCollectedDataTypeOtherDiagnosticData`, 목적 앱 기능·분석, 연결 안 됨·추적 안 함)을 더할지 판단해 넣는다. ASC 라벨과 문면이 어긋나면 ASC 쪽이 정본이다(아래 5).
5. **App Store 개인정보 라벨 확인**: Taption Plan의 ASC 개인정보 라벨에 **위치(정확·대략)**가 어떤 목적으로 적혀 있고, **진단 데이터** 항목이 있는지 읽어 본다. PostHog 전송이 드러나지 않으면 회신에 한 줄로 적는다(라벨 수정은 별도 작업 — `notes/bokki-encoder-aso/privacy-label-check-2026-11-18.md` 방식으로 「있는 것/없는 것/어긋난 것」만). ASC 접근이 없으면 「확인 못 함」으로 적고 넘어간다.
6. **표시·기록 금지**: 키·토큰, 사용자의 계정·메일, 실제 좌표를 화면·로그·시험·회신 어디에도 쓰지 않는다. 시험은 가짜 좌표만.

## 7. 지우는 것과 남기는 것 (확인함)

**지운다**
- `developerMailButtons` 호출(338)과 `extension MapHomeSecuritySheet`(803~858) 전체, `developerMailStatus`·`developerAttachment` 상태(208·209), 안내문 「위치 기록이 포함될 수 있어요. 메일 화면에서 보내기를 눌러야 전송됩니다.」, 이 화면의 `.sheet(item: $developerAttachment)`.

**남긴다 (지우면 다른 기능이 깨진다)**
- `TaptionPlan/UI/MapHomeDeveloperMail.swift` 전체 — `MapHomeDeveloperMailSheet`·`MapHomeDeveloperAttachment`를 **장소 요청 메일**이 쓴다(`MapHomePlaceBookTools.swift:578·644·676`). `MapHomeZipArchive`도 이 파일에 있으니 손대지 않는다(쓰는 곳이 없어져도 파일 삭제는 대표 확인 대상).
- `exportTodaySensorRawURL()` — DEBUG `-exportRawOnLaunch`가 쓴다(`AppModel+Export.swift:64`).
- `TaptionPlanDiagnosticsICloudExporter`·`TaptionDiagnosticsLatestLogManifest`와 그 시험 — iCloud entitlement(`ubiquityContainerURL`, iCloud.com.taption.plan)도 **이번에 지우지 않는다**(백업·PIN이 쓴다: `BackupPasswordVault`·`AssistantPINDerivation` 확인). 이번 흐름에서 부르지 않게만 한다.
- `MapHomeView.swift:627·657`의 벤치: `exportDiagnosticsToICloud()` 대신 **로컬 패키지만 만드는 함수**(예: `makeDiagnosticsPackageLocally()`)를 부른다. 무인 벤치가 PostHog로 나가면 안 된다.

## 8. 작업 순서 (제안)

1. `AppModel+Export` 자료 만들기 분리(`todaySensorRawExport()`·`makePackageText`), 기존 시그니처 유지.
2. `TaptionPlan/Core/PostHogDiagnosticsUploader.swift`(새 파일, 앱 target) — 키 읽기, 이벤트 만들기, 배치·조각 자르기, gzip, `POST /batch/`, 응답 해석, 진행 콜백. URLSession은 `URLSessionConfiguration.ephemeral`에 요청 20초·리소스 120초, `waitsForConnectivity = false`. 시험에서 갈아끼울 수 있게 **전송 sink를 주입**받게 한다(시험은 네트워크를 타지 않는다).
3. `AppModel` 상태·함수 교체(`uploadDiagnosticsToPostHog()`, `uploadSensorRawToPostHog()`), 실패 사유·재시도 상태.
4. `MapHomeSettingsSheets` 화면(3절), 삭제(7절).
5. xcconfig·Info.plist, `PRIVACY.md`·`PrivacyInfo.xcprivacy`·`AGENTS.md` 4절 — 같은 커밋.
6. 문구 12개 언어(`extract.py` → 번역 → `check.py` 실패 0), `DEVELOPMENT.md`에 한 절(키 위치·이벤트 이름·배치 규칙·한도 대응).
7. 빌드·단위 시험(9절), 구조 검사 2종, 실기기(10절).

## 9. 단위 시험 (최소)

새 파일 `TaptionPlanTests/PostHogDiagnosticsUploaderTests.swift`(+ 필요하면 `DiagnosticsLogSupportTests`에 1건).

1. **로그 payload에 좌표·원본 센서가 없다**: 만든 이벤트의 모든 속성 문자열·JSON에 `latitude`/`longitude`/`lat`/`lon`/`SensorReading` 흔적이 없고, `travel_mode_counts`·`subway_lines`는 있다.
2. **원본 payload에 GPS가 있고 배치가 상한을 넘지 않는다**: 가짜 표본 1,200개 → 배치가 500 이하·배치 JSON 256KB 이하, 각 이벤트 1MB 이하, `samples_total`·`batches_total` 합이 맞고 첫 표본의 좌표가 그대로 실린다.
3. **키 없음**: `POSTHOG_API_KEY`가 빈 문자열·`$(POSTHOG_API_KEY)`일 때 `isConfigured == false`, 버튼 비활성 판단, 상태 문구 「설정 안 됨」.
4. **실패 시 로컬 파일 남음·사유 표시**: sink가 500을 돌려주면 패키지 파일과 원본 JSON이 남아 있고, 상태에 응답 사유가 그대로 들어간다.
5. **재시도가 성공분을 건너뛴다**: 3배치 중 2번째에서 실패 → 재시도 요청에 0·2번만 들어간다(1번 없음).
6. **로그 조각 자르기**: 500KB 로그 → 조각이 200KB 이하, 이어 붙이면 원문과 같다(해시 일치).
7. **429·402 문구**: 응답 코드별로 화면 문구가 갈린다.

기존 시험(패키지 빌더·iCloud exporter 4건)이 **그대로 통과**해야 한다.

## 10. 실기기 검증 (회신에 숫자로)

기본은 **아이폰 11 Pro**(AGENTS.md 4절), 대표가 아이폰 18을 고르면 그 결과를 따로 적는다.

1. **로그 업로드**: 1회 눌러 `이벤트 수·용량(압축 전/후)`·걸린 초를 적고, PostHog(Activity → Events, 필터 `app = bokki-plan` AND `source = diagnostics`)에서 보이는지 스크린샷/이벤트 수로 확인.
2. **어제·오늘 원본**: 1회 눌러 `배치 수·표본 수·용량`·걸린 초, PostHog에서 `source = sensor_raw` 이벤트 수, 한 이벤트가 1MB를 넘지 않았는지(가장 큰 이벤트 크기) 확인. 표본 수는 그 기기의 실제 기록에서 나온 값을 그대로.
3. **키 없음**: 로컬 xcconfig를 비운 빌드(아니면 키 읽기를 빈 값으로 바꾼 시험 빌드)에서 두 버튼 비활성·「설정 안 됨」.
4. **실패**: 비행기 모드에서 눌러 `실패 · <사유>`와 로컬 파일 남음, 모드 해제 뒤 **「재시도」** 성공(성공분 건너뜀).
5. **동의 흐름**: 처음 누르면 확인, 「다시 묻지 않기」 체크 뒤 두 번째부터 안 뜸, 「다시 묻기」로 되돌아감.
6. **한도 응답**: 강제로 흉내 낼 수 있으면(예: 잘못된 키) `401` 사유가 화면에 그대로 보이는지. 실제 429를 만들려고 일부러 한도를 태우지 말 것.

## 11. 문서·기록

- `test.md`: 요청 ID **PHG1120A01** — `## 남은 작업`의 「홈·UI」에 한 줄, `### 요청 상세`에 원인·해결·검증 기준, `## 검증 기록`에 결과 절(실행 명령·측정값), `## 실기기 확인 목록` 아이폰 11 Pro 표에 손 순서. **`docs/pipeline/CHANGELOG.md`는 저장소에 없다**(2026-11-20 확인) — 새 이력 문서를 만들지 않는다.
- `AGENTS.md` 4절: 6절 2의 문구(대표 결정 2026-11-20).
- `PRIVACY.md`: 6절 3. `TaptionPlan/PrivacyInfo.xcprivacy`: 6절 4.
- `DEVELOPMENT.md`: 한 절 — 키 위치(`AppSecrets.local.xcconfig`)·이벤트 이름·배치 상한(500표본/256KB/이벤트 1MB/요청 3MB)·`$insert_id` 재시도 규칙·한도 응답 표시.
- 선택: `docs/CLIENT_REPORT.md`의 「계측이 현재 0이다」 문장에 한 줄(이제 진단 업로드만 PostHog로 간다) — 고칠지는 판단에 맡긴다.

## 12. 하지 말 것

- **PostHog SDK·새 의존성 추가**, 패키지 추가, 유료 인프라·구독.
- **키·토큰을 커밋되는 파일·코드·시험·로그·회신에 쓰기**(로컬 xcconfig에만).
- **좌표를 다른 목적으로 넓히기**: 제품 행동 추적·앱 실행 이벤트·세션 리플레이·자동 오류 리포트로 확대하지 않는다. 이번은 사용자가 누른 두 버튼의 진단뿐이다.
- 자동·백그라운드·앱 시작 시 전송, 실패 자동 재시도 루프.
- **iCloud entitlement·`ubiquityContainerURL`·`TaptionPlanDiagnosticsICloudExporter` 삭제**(백업·PIN이 쓴다).
- `MapHomeDeveloperMail.swift` 파일 삭제, 장소 요청 메일 흐름 손대기.
- 동결 파일 수정: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`. `MapHomeView.swift` 본 파일에 `@State`·저장 속성 더하지 않기.
- `try!`·`Task.detached`(기존 사용처 제외)·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`·`DispatchQueue.main` 늘리기, `docs/architecture-baseline.json` 고치기, 새 파일 1,200줄 넘기기.
- 다른 세션의 미커밋 변경(`TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`) 커밋 포함. 경로를 지정해 이번에 만진 파일만 커밋.
- 서버(`server/trip-relay`)·Cloudflare 자원 변경·배포, TestFlight 업로드.
- 시험에서 실제 네트워크·실제 좌표·실제 집/회사 이름 쓰기.
- 돌리지 않은 시험을 통과로 적기, PostHog 화면 확인 없이 「도착했다」고 적기.

## 13. 회신에 담을 것 (`pickle-bridge/README.md` 4절 형식)

- 처리: 완료 / 일부 / 막힘 · 요청 ID(PHG1120A01) · 시작·끝 · 커밋 해시(작업 커밋·문서 이동 커밋)
- **바뀐 화면**: 카드 제목·설명·두 버튼 라벨·고지·동의 흐름, 삭제한 메뉴(잔여 참조 0 확인 방법: `rg`)
- **실측**: 로그 업로드 이벤트 수·용량(압축 전/후)·초, 원본 배치 수·표본 수·가장 큰 이벤트 크기·초, PostHog 필터(`app = bokki-plan`, `source`)로 본 이벤트 수
- **이벤트 이름·속성 표**(`plan_diagnostics_log`·`plan_diagnostics_raw_meta`·`plan_diagnostics_raw_batch`)와 `$insert_id` 중복 제거가 실제로 먹었는지(재전송 1회 결과)
- **키 처리**: 로컬 xcconfig에만 있음(`git status`로 무시 확인), 커밋된 파일에 없음, 회신에 키를 쓰지 않음
- **개인정보**: `PRIVACY.md`·`PrivacyInfo.xcprivacy`·`AGENTS.md` 4절 문구 변경 요약, ASC 라벨에서 확인한 것/못 한 것 한 줄
- 바꾼 파일, 검증(단위 시험 실행 수·실패·건너뜀, 구조 검사 2종), 실기기 확인 목록 ID, 번역 대기·추가 문구 수
- 남긴 것과 이유(`MapHomeDeveloperMail.swift`·iCloud exporter·`exportTodaySensorRawURL`), 하지 않은 것(서버·SDK·자동 전송)
- 막혔으면 파일을 `done/`으로 옮기지 말고 `status: blocked` + 객관식 질문(추천을 첫째에)

## 참고

- 이 지시서 2절의 파일:줄은 2026-11-20 18:05 `48423c1a`에서 확인한 것이다. 착수 때 `rg -n`으로 다시 확인하고 달라졌으면 회신에 적는다.
- PostHog capture 규격: `POST https://us.i.posthog.com/batch/`, 본문 `{api_key, batch:[{event, properties, timestamp}]}`, 요청 본문 기본 20MB·이벤트당 약 1MB, gzip은 `Content-Encoding: gzip`, 익명은 `$process_person_profile: false` + 무작위 distinct_id (PostHog 문서 「Capture and batch API endpoints」).
- 같은 프로젝트를 쓰는 다른 앱의 관례(참고용, 저장소는 다름): BOKKI Encoder의 `Config/PostHog.xcconfig`(공개 템플릿, 빈 `POSTHOG_API_KEY` + `#include? "PostHog.local.xcconfig"`)와 `TaptionEncoder/Core/Diagnostics/ProductAnalytics.swift`(호스트 `https://us.i.posthog.com`, 가림 처리 후 전송). 이 저장소에서는 `AppSecrets` 방식으로 같은 모양을 만든다.
- 지금 동작: `MapHomeSettingsSheets.swift:288~340`, `AppModel+Export.swift:36·93·103·115·193`, `DiagnosticsLogSupport.swift:6·267·695·717·812`.
- 규칙: `AGENTS.md` 3·4·5·6·7·8·9·12절, 브리지 형식: `pickle-bridge/README.md`.

## 점검 회신 (비야, 2026-11-20 18:51)

- **보안: 4.1에 PostHog 프로젝트 API 키 값이 그대로 적혀 있어 자리표시자로 바꿨습니다**(값은 여기에 옮기지 않습니다). 넣는 곳은 git 무시 `TaptionPlan/AppSecrets.local.xcconfig` 하나로만 남겼습니다. **이미 `origin/main`에 커밋된 이력에는 값이 남아 있습니다** — 지우기로는 없어지지 않으니 대표가 PostHog에서 키를 회전할지 판단해야 합니다(문서 4.1 끝에 그 한 줄을 넣었습니다).
- 키가 없을 때의 처리도 명시했습니다: 버튼 비활성·「키가 설정되지 않았습니다」 상태로 **코드·시험을 끝까지 넣고 회신**하며, `status: blocked`로 두지 않습니다.
- 진단 로그·PRFBENCH에 요청·응답 본문을 남기지 않도록 4.4에 한 줄 더했습니다(헤더의 키·배치의 좌표가 샐 수 있음). 남길 것은 이벤트·배치 수, 바이트, 응답 코드, 걸린 초뿐입니다.
- 개인정보 고리는 그대로 확인했습니다: 원본 업로드는 버튼+동의(1회, 되돌리기 있음)에만, 자동·백그라운드 전송 없음, `AGENTS.md` 4절 다섯 번째 좌표 예외·`PRIVACY.md`·`PrivacyInfo.xcprivacy`를 **같은 커밋**에 넣도록 되어 있습니다(배포 전 확인 항목).
- 처리 순서를 머리에 넣었습니다: RTA1120A01 다음, 시작 경로·중계 서버 문서와 파일이 겹치지 않음.
- 2절 표의 파일:줄은 18:4x `origin/main`에서 맞았습니다(`MapHomeSettingsSheets` 194·207~209·288·298·323~326·338·803, `AppModel+Export` 36·64·93·103·115). 고치지 않은 것: 이벤트·배치 상한(500표본/256KB/1MB/3MB)과 `$insert_id` 규칙은 제안대로 두었습니다.
