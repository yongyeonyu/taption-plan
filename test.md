# Taption Plan 실기기 검증

## 2026-08-31

- 대상: iPhone 14 Pro (`C44AF739-127D-572D-AD83-417C7E879045`)
- 서명 Debug 최신 소스 빌드: 성공 (`1.0 (119)`, `com.taption.plan`, `/tmp/TaptionPlan-device-build-20260831-paid-type/Build/Products/Debug-iphoneos/TaptionPlan.app`)
- 설치: 성공 (최신 product-type 보강 소스)
- 설치 readback: `xcrun devicectl device info apps`에서 `Taption Plan com.taption.plan 1.0 119` 확인
- 최신 소스 재실행: 성공 (`xcrun devicectl device process launch`, exit 0)
- 수신 요청 대기 표시를 포함한 최신 Debug 빌드(`/tmp/TaptionPlan-device-build-20260831-watch-feedback/Build/Products/Debug-iphoneos/TaptionPlan.app`)는 재설치 중 CoreDevice 연결 timeout으로 설치 readback을 확보하지 못함
- 09:35:56 미러링 `다시 시도` 후에도 “iPhone을 찾을 수 없음”으로 종료됐고, CoreDevice 재확인에서 iPhone·Apple Watch 모두 `unavailable`
- 화면: iPhone 미러링으로 Taption Plan 실제 지도 화면 진입 확인
- 터치: 미완료. 터치 시도 직후 `iPhone 사용 중`으로 미러링이 종료되고 `연결하려면 iPhone을 잠그십시오` 안내가 표시되어 직접 터치·저장 readback을 확보하지 못함
- Apple Watch: 메뉴의 최신 실제 수신 시각 표시와 receipt 저장·복원 단위 테스트는 통과했지만, 현장 설치·수신·동기화는 미완료. `available (paired)`가 일시 표시된 뒤 설치 명령에서 CoreDevice가 기기를 찾지 못했고, 09:10:58~09:11:54 재확인은 계속 `unavailable`이었다

## 2026-08-31 iPad 보조 검증

- 대상: iPad Pro (12.9-inch) (6th generation), `4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`
- 최신 소스 서명 Debug `1.0 (119)` 설치: 성공 (`databaseSequenceNumber: 6160`)
- 설치 readback: `Taption Plan com.taption.plan 1.0 119` 확인
- 최신 소스 launch: 성공 (`xcrun devicectl device process launch` exit 0)
- 화면·터치: CoreDevice에 screenshot/직접 터치 경로가 없어 미완료. `idevicescreenshot`은 이 CoreDevice UDID를 찾지 못함

## 2026-08-31 시뮬레이터·자동 검증

- 대상: `MAP30CNT01 Test` (`37ED8B8E-1EA0-43DF-BC49-D43B91CC3A0A`)
- 무료 체험 시작 후 앱 종료·재실행: 지도 복귀 확인
- 사이드 메뉴: 자동 센서 권한이 없어도 수동 기록·지도 메모 사용 가능 문구와 권한 요청 버튼 확인
- 지도 메모: 추가 화면에서 `지도 메모 추가`, 날짜·시간·위도·경도 표시 확인
- 지도 메모 취소: 편집 화면 취소 동작 후 지도 복귀 확인
- 지도 메모 draft: 취소 시 정본에 저장하지 않는 회귀 테스트 확인
- 관련 테스트: `TaptionPlanTests` 852건 성공 (`/tmp/TaptionPlan-full-2026-08-31-watch-feedback-final.xcresult`, `852 passed / 0 failed / 0 skipped`)
- 결제 상품 타입 보강 기준 XCTest: 852건 성공 (`/tmp/TaptionPlan-full-2026-08-31-paid-type.xcresult`, `852 passed / 0 failed / 0 skipped`)
- 최신 dirty 소스 iOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-release-20260831-paid-type/Build/Products/Release-iphoneos/TaptionPlan.app`); embedded Watch app과 Widget 포함
- 최신 dirty 소스 watchOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-watch-release-20260831-paid-type/Build/Products/Release-watchos/TaptionPlanWatch.app`)
- 수신 요청 대기 표시 포함 최신 dirty 소스 iOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-release-20260831-watch-feedback/Build/Products/Release-iphoneos/TaptionPlan.app`); embedded Watch app·Widget 포함
- 수신 요청 대기 표시 포함 최신 dirty 소스 watchOS Release generic build: 성공 (`1.0 (119)`, `/tmp/TaptionPlan-watch-release-20260831-watch-feedback/Build/Products/Release-watchos/TaptionPlanWatch.app`)
- 미래 예보: WeatherKit/Open-Meteo hourly forecast를 `isForecast`로 관측값과 구분하고 SQLite round-trip하는 회귀 테스트 통과
- Watch receipt: 측정 시각과 실제 수신 시각 분리, envelope 도착 시각의 callback 전달, 지연 payload의 최신 수신 판정, reload 보존 회귀 테스트 통과
- 빈 health 응답: 값이 없는 health snapshot도 `health` receipt와 최신 수신 시각을 기록하는 회귀 테스트 통과
- Watch 요청 피드백: 전송 접수 시 요청 시각을 표시하고 실제 envelope 수신 시 최신 수신 시각으로 전환하는 소스·컴파일 검증 완료. 실기기 버튼·수신 전환은 Watch 연결 불안정으로 미완료
- 계획 삭제 보존: 로컬 계획 삭제 후 연결된 지도 메모의 계획 연결만 해제되고 좌표·발생 시각·본문이 저장소 readback에 남는 회귀 테스트 통과
- 시간 경계: 계획 종료 시각의 지도 메모가 종료된 계획에 연결되지 않는 회귀 테스트 통과
- 동시 저장: 편집 중 미저장 지도 메모 draft가 저장소 readback에 남지 않는 회귀 테스트 통과
- 시간 재연결: 지도 메모를 다른 계획 시간으로 옮기면 재연결되고 계획 종료 시각에서는 독립 메모로 분리되는 회귀 테스트 통과
- 초안 삭제: 지도 메모 초안을 일반 삭제해도 저장소와 Cloud tombstone에 남지 않는 회귀 테스트 통과
- 재생 cutoff: 일간 지도 재생 중 playhead 이후 지도 메모를 숨기고 동시각 메모를 포함하는 회귀 테스트 통과
- 필터 UI: 표시 메뉴에서 모든 지도 메모/일정 관련 메모를 선택하고 설정이 저장되는 UI 경로 반영
- build 120 Release archive/export: 성공 (`/private/tmp/taption-rel8310001.xcarchive`, `/tmp/taption-rel8310001-export/TaptionPlan.ipa`); IPA SHA-256 `65003366d03503c02afd87d8fc17a301ce75e08ea5cb9ba0a5986c605d562d39`, `codesign --verify --deep --strict` 통과.
- build 120 TestFlight 업로드: 성공, Delivery UUID `d0c6d36b-5978-40c0-9027-bb3169d0cae6`; `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, App Store Connect 등록 및 version `120` readback.
- build 120을 `TP Taption Plan 내부 테스트`에 연결하고 그룹 상세에서 `1명의 테스터 · 81개의 빌드`, `1.0 (120) · 테스트 중` 노출을 확인했다. 테스터 화면은 1명 노출을 확인했으며, 현재 설치 표시는 기존 `1.0 (119)`이고 build 120 설치 readback은 아직 없다.
- App Store Connect read-only 확인(09:55:39 KST): Chrome에서 `axony99@gmail.com` 계정으로 로그인된 세션과 `Taption Plan` 앱 접근을 확인했다.
- 기존 TestFlight build 119: `제출 준비 완료`, `TP Taption Plan 내부 테스트` 그룹 노출, 설치 1건을 확인했다. 그룹 상세는 `내부 그룹 · 1명의 테스터 · 80개의 빌드`, 테스터 `axony99@gmail.com`의 `설치됨 1.0 (119)` 및 2026년 8월 31일 readback을 확인했다.
- Paid Apps Agreement: 비즈니스 계약 표에서 `유료 앱 계약 · 신규`로 표시되어 활성 계약이 아니다. `무료 앱 계약`은 2026년 8월 19일~2027년 6월 3일 `활성화됨`이다.
- 앱 내 구입: `/apps/6797370230/distribution/iaps`가 빈 상태이며 `com.taption.plan.pro` 상품은 App Store Connect에 아직 생성되지 않았다. 계약 서명·상품 생성·sandbox 구매 검증은 미완료다

## 2026-08-31 지하철·예상경로·Apple Watch 진단

- iCloud 조회 범위: 2026-08-31 00:00~12:28 KST. 별도 `TaptionLogs` export는 2026-08-16이 최신이지만, 메뉴의 iCloud 백업 경로 `iCloud.com.taption.plan/Documents/Taption Plan/2026-08.taptionbackup`와 `Raw Sensors/2026-08.rawsensorbackup`가 2026-08-31 12:47에 갱신되어 백업 성공을 확인했다. 암호화 payload를 읽기 전용으로 복호화해 오전 여행 구간 7개 중 `09:31~10:06 KST` 지하철 1개와 `인천2호선·공항철도`를 확인했다.
- 같은 범위 raw sensor는 684건 모두 iPhone이며 Watch source는 0건, `nearbyStation`·철도/대중교통 플래그·역 이름은 모두 0건이었다. 따라서 백업은 존재하지만 이 백업 안에는 Watch 원본과 역 체류 근거가 들어오지 않았다.
- 역 후보 진단: `transit_boarding_candidates_evaluated`에 입력 reading·GPS/정확도·등록/주변 장소·powered travel·후보 수·후보명·연결 구간 수를 기록하도록 했다.
- 예상경로 진단: `expected_route_requests_built`, `expected_route_projection_built`, `expected_route_network_resolution`, `expected_route_state_applied`에 요청·중복 segment·forecast/gap·시간 겹침·동일 endpoint·generated 수와 phase를 기록하도록 했다. 백업은 성공했지만 payload가 암호화되어 포함 로그를 아직 직접 읽지 못했으므로 첨부 화면의 과다 점선 원인은 확정하지 않았다.
- Apple Watch 진단: `설정 메뉴 > Apple Watch 데이터`의 버튼 탭·전송 접수/거부·transport·envelope·sensor/health decode·receipt 저장·대기 해제를 요청 ID로 연결하도록 했다. 백업 내부의 8/31 Watch 요청은 `reachable=false`였고 envelope 수신 이벤트가 없었다. 당시 iPhone·Watch 연결 및 Watch 잠금 해제는 사용자 확인이지만, 실제 데이터 전달은 확인되지 않았고 현재 CoreDevice 재확인에서는 iPhone·Watch 모두 `unavailable`이다.
- 자동 검증: 역 후보 관련 XCTest 10건, `RouteTimelineDataTests` 단독 실행 exit 0, `WatchSensorQueryPlanTests` 단독 실행 exit 0, iOS Debug 및 watchOS Debug build 통과. forecast 투영에서 명시 이동과 겹치는 gap 및 동일 endpoint·시간 중복 이동을 제거하는 보정을 반영했다. 백업에 새 예상경로 진단 이벤트가 없고 오전 travel 자체에는 동일 endpoint 중복이 없어 점선 중복 원인은 미확정이며, 새 빌드 실기기 재현·Apple Watch 실제 수신 전환은 미완료다.
- `LIN8310001` 정합성 보정: visible forecast leg ID를 기준으로 재생 frame을 선택하고, MapKit 점선 좌표도 동일한 `MapHomeWBSPlaybackProjection`에서 잘라 사용하도록 통합했다. 재생 중 cutoff는 지연된 `routeProjection.cutoff`가 아닌 동일한 fractional playhead를 사용하며 `expected_route_playback_alignment` 진단 로그를 추가했다.
- `LIN8310001` 회귀: `RouteTimelineDataTests`·`TimeScaleTests` focused XCTest 통과, 전체 `TaptionPlanTests` 통과 (`/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.08.31_18-41-48-+0900.xcresult`), iPhone 14 Pro 시뮬레이터 Debug build `** BUILD SUCCEEDED **`.
- `LIN8310001` 실제 iPhone 화면 재생·터치 및 Watch 현장 검증은 아직 수행하지 않았다.

### 미완료 게이트

- iPhone 14 Pro에서 최신 Debug 빌드의 실제 화면 진입·지도 메모 추가·시간/좌표 readback·터치 확인
- Apple Watch 현장 설치·수신·동기화 확인
- 새 변경분 TestFlight 업로드·처리·`TP Taption Plan 내부 테스트` 그룹 연결·빌드/테스터 노출 확인
- Paid Apps Agreement 활성화·`com.taption.plan.pro` 생성·sandbox 구매/복원 확인
