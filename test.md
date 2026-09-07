# Taption Plan 실기기 검증

## 2026-09-07 WAK907A001 졸라맨 좌표 표시

- Apple 지도와 Vector 지도의 졸라맨 발끝 anchor를 동일한 경로 좌표로 통일했다.
- anchor 회귀 1/1과 Simulator Debug build가 통과했다: `/tmp/WAK907A001-tests-r2.xcresult`.
- TestFlight에서 같은 시각을 유지한 채 줌인·아웃했을 때 발끝이 동일 경로 좌표에 남는지 실제 터치 확인은 별도 게이트다.

## 2026-09-07 IAP907B001 구매 비활성화·TestFlight build 140

- 구매 정책 OFF에서 만료 기록도 접근 허용, 상품 미로드, 직접 구매·복원 무호출을 집중 XCTest 2/2로 확인했다: `/tmp/IAP907B001-tests-r2.xcresult`.
- Release archive/export·배포 서명·TestFlight entitlement·`altool --validate-app` 통과, 네 번들 `1.0 (140)`, IPA SHA-256 `ebf0161b10decb17765eda07f2dea6d3b304320ab79fea57cf103c14bdbf5147`: `/private/tmp/IAP907B001.jpbHS0`.
- Delivery/build UUID `c871d1f4-e933-411d-b840-0d59af3ba6be`는 `COMPLETE`·`VALID`·미만료이며 Internal 그룹 build 140과 테스터 1명 `INSTALLED`를 API readback했다.
- TestFlight 앱에서 build 140 설치·launch·구매 UI 비노출·만료 상태의 전체 기능 접근은 물리 게이트다.

## 2026-09-07 TFB907A001 TestFlight build 139

- 개발자 체험 초기화 집중 XCTest 1/1과 Simulator Release build가 통과했고, Release 바이너리에는 Debug 초기화 경로가 없다: `/tmp/TRY907A001-tests-r2.xcresult`, `/tmp/TRY907A001-release-dd`.
- 네 번들 `1.0 (139)` Release archive/export·배포 서명·TestFlight entitlement·`altool --validate-app`을 통과했다. IPA SHA-256은 `65c95869f99112813f4d5f0fed5be638fab7e53b822da4a131567188113ddde5`다: `/private/tmp/TFB907A001.j36e1d`.
- Delivery/build UUID `23d0de21-0047-40f1-b681-30bbfb8d26ca`는 `VALID`·미만료이며 내부 그룹 관계에서 build 139와 테스터 1명 `INSTALLED`를 API readback했다.
- Chrome 세션 인증 만료로 그룹 빌드·테스터 화면 확인은 미완료다. TestFlight 앱의 build 139 설치·샌드박스 Pro 구매·launch·실제 기능 테스트도 물리 게이트다.

## 2026-09-06 DEV906I001 iPhone 설치

- 최신 `main@7a490e9` Apple Development Debug를 deep/strict codesign 후 iPhone 14 Pro에 설치했다.
- `com.taption.plan 1.0 (138)`·`builtByDeveloper=true`·launch PID `16713`을 readback했다: `/private/tmp/DEV906I001-install.json`, `/private/tmp/DEV906I001-apps.json`, `/private/tmp/DEV906I001-launch.json`.
- 실제 등록 장소 축소 화면 터치와 TestFlight 클라이언트는 별도 게이트다.

## 2026-09-06 PIN906A001 등록 장소 좌표 표시

- Apple·Vector 지도 등록 장소 카드의 하단 anchor를 제거하고 아이콘 중심을 저장 좌표에 일치시켰다.
- anchor·현재 위치 회귀 2/2와 Simulator Debug build·설치·launch PID `17961`이 통과했다: `/private/tmp/PIN906A001-focused-r2.xcresult`.
- 실제 축소 화면의 손가락 확인은 물리 iPhone 게이트다.

## 2026-09-06 LOC906F001 현재 위치 이중 포커싱

- 캐시 좌표 선이동과 새 GPS 후속 이동을 제거하고, 새 표본 저장 뒤 한 번만 포커싱하도록 수정했다.
- 위치 갱신 게이트 회귀 1/1과 Simulator Debug build·설치·launch PID `13086`이 통과했다: `/private/tmp/LOC906F001-focused-r3.xcresult`.
- 실제 손가락 탭과 GPS 이동은 물리 iPhone 게이트다.

## 2026-09-06 SUB906R001 00:17 지하철 오탐

- 00:17 당시 설치본은 build 137이며, 동일 날짜 진단은 철도·역·대중교통·후보·노선 0인데 지하철 1건과 잠금 5건을 기록했다.
- 역 인접만으로 상대고도 하강 점수를 주지 않도록 수정했다. 관련 Simulator XCTest 4/4, Debug build, 설치·launch PID `5406`이 통과했다: `/private/tmp/SUB906R001-focused-r4.xcresult`.
- 최신 Apple Development Debug `1.0 (138)`의 iPhone build·설치·`builtByDeveloper=true`·launch PID `16511`을 readback했다: `/private/tmp/SUB906R001-device-install.json`, `/private/tmp/SUB906R001-device-apps.json`, `/private/tmp/SUB906R001-device-launch.json`. 실제 자동차 이동 재현은 미완료다.

## 2026-09-06 NXT906P002 졸라맨 중앙 포커싱

- 현재 위치 목표점 x를 전체 viewport 중앙으로 통일하고 검색창 아래 y 여백은 유지했다. 수학 회귀 1/1과 camera command·버튼 상태 회귀 2/2가 실패·스킵 없이 통과했다: `/private/tmp/NXT906P002-focused.xcresult`, `/private/tmp/NXT906P002-camera-command-r2.xcresult`.
- 최종 소스의 Simulator Debug build가 통과했다. 물리 iPhone은 `unavailable`이라 실제 손가락 현재 위치 버튼·TestFlight 화면 중앙 정렬은 별도 게이트다.

# 2026-09-06 SUB906F001 지하철 오탐 수정·TestFlight build 138

- iCloud 로그에서 `reading_rail_match_count=0`, `reading_station_name_count=0`, `reading_transit_match_count=0`, `candidate_count=0`인데 `subway_segment_count=1`이 남아 미확정 잠금 보존을 원인으로 확정했다: `/private/tmp/DAY906L001-current-iphone.jsonl`.
- Apple Watch 출처·신뢰도 조건을 지하철 행동 보조 근거에 적용하고, 노선 없는 미확정 잠금은 새 이동 결과로 재평가했다. 지하철 집중 18/18, `TaptionActivityEngineAdapterTests` 16/16, Swift Package 회귀가 통과했다.
- Release archive/export·`altool --validate-app` 통과, 네 번들 `1.0 (138)`, IPA SHA-256 `9fa557d536c6002294abf2a3435c54f0c8742df533577f69d411f467eb9a36f7`: `/private/tmp/SUB906F001-release`.
- TestFlight 업로드 Delivery UUID `9caa4563-2a99-4b1a-ab58-c5b4a74b663c`; API readback에서 build 138 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 build 99개 중 build 138과 내부 테스터 1명(`INSTALLED`)을 확인했다.
- build 138 TestFlight 설치·실행 및 실제 사용자 기록 재검증은 물리 게이트다.

## 2026-09-06 PAY906Q001 데이터·지도 집중 검증

- iPhone 14 Pro(iOS 26.6.1)에서 raw 복원 실패 원자성, Watch 원본 보존, 캘린더 계정·반복 일정 병합, 지도 cache·pinch 재중심화 회귀 11/11을 실패·스킵 없이 통과했다: `/private/tmp/PAY906Q001-focused-r1.xcresult`.
- 날씨 rail 간격과 pinch 유지 추가 회귀는 iPhone 17 Pro iOS 26.5 Simulator에서 2/2 통과했다: `/private/tmp/PAY906Q001-weather-r2.xcresult`.
- 같은 Watch summary/chunk identity의 동일 재전송은 no-op, 다른 payload는 거부하는 원본 불변 회귀 2/2를 통과했다: `/private/tmp/PAY906Q001-focused-r4.XPUojy/focused-r2.xcresult`.
- 최신 전체 XCTest·Swift Testing은 1,050건 중 1,049 passed·1 skipped·0 failed다: `/private/tmp/PAY906Q001-latest-analyze/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 `SKInternalErrorDomain Code=3` StoreKitTest 시스템 오류다. 최신 iOS static analyzer도 analyzer 경고·오류 0이며 Xcode StoreKitTest SDK 헤더 폐기 경고 1건만 보고했다: `/private/tmp/PAY906Q001-latest-analyze/analyze.xcresult`.
- 30일 날짜 조회 cold/warm p95는 `25.605708ms`/`0.009167ms`, legacy 100건 복구는 `46.960084ms`, inline legacy 2,346건은 `118.320083ms`다.
- XCTest 산출물이 없는 일반 시뮬레이터 앱을 설치·launch하고 동일 1206×2622 전후 화면에서 레이아웃·날씨 라벨·현재 위치 버튼을 함께 비교했다: `/private/tmp/PAY906Q001-design-audit-final/02-before-after.png`.
- 메모 메뉴의 수정 전후를 동일 1206×2622 상태로 결합 비교해 `note.text`·금색 계열 통일과 레이아웃 유지가 보였다: `/private/tmp/PAY906Q001-design-audit-r2/11-before-after-memo.png`. Vector 임시 마커 anchor와 44/48pt hit target, Apple annotation 언어별 접근성 라벨은 코드·빌드로 확인했지만 실데이터 마커와 VoiceOver 낭독은 별도 물리 게이트다.
- 최신 일반 Debug `1.0 (137)`은 테스트 번들 없이 deep/strict codesign 후 iPhone 설치·developer app 버전 readback·launch PID `14539`를 통과했다: `/private/tmp/PAY906Q001-style-iphone-r1.k3QEtD`. 위치 버튼 회귀는 iPhone 17 Pro iOS 26.5 Simulator에서 1/1 통과했다: `/private/tmp/PAY906Q001-style-simtest-r1.3FJtFo/focused.xcresult`.
- 현재 launch의 앱 진단 파일은 생성되지 않아 새 runtime 로그 readback은 확보하지 못했다. 실제 두 손가락 pinch·장시간 발열/배터리·Watch/캘린더 실계정 수신·대중교통 경로 화면은 별도 물리 게이트다.
- snapshot 저장 실패 뒤 새 raw만 되돌리는 복원·Watch 회귀 7/7, 사용자가 선택한 캘린더가 새 live 캘린더 때문에 확대되지 않는 회귀 2/2, pending viewport 중복 재중심화를 막는 카메라 회귀 4/4와 TaptionPlanCore 52/52를 통과했다: `/private/tmp/RAWAUD9061-focused/cloud-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/calendar-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/map-camera-regression.xcresult`, `/private/tmp/RAWAUD9061-focused/map-current-location-regression.xcresult`.
- 최신 일반 Debug `1.0 (137)`은 테스트 번들 0개·deep/strict codesign 후 iPhone 설치·developer app 버전 readback·launch PID `14718`을 통과했다. Debug dylib SHA-256은 `c6fb740fbd97837e99e48905fe2490da4a2f2f1aa602b9745ee9d2ce813cadf2`다: `/private/tmp/PAY906Q001-iphone-final-r5/evidence.md`.

## 2026-09-06 RTE906C001 반복 날짜 로드 회귀

- 지도 화면의 60초 전체 날짜 재조회와 같은 날 소스 변경에 따른 task 재시작을 제거했다. task key 집중 회귀 1/1, generic Simulator Debug와 iPhone Debug build가 통과했다: `/private/tmp/RTE906C001-focused.xcresult`.
- iPhone 14 Pro(iOS 26.6.1)에 개발자 서명 `1.0 (137)`을 설치하고 버전·launch·프로세스 PID `15114`를 readback했다. Debug dylib SHA-256은 `4b9b38e2a70842f1768b66497be61cbb0d910b46b5b48a0334aefa6308da465c`다: `/private/tmp/RTE906C001-device-evidence.md`.
- 설치·실행은 통과했지만 실제 손가락 날짜 전환 지연과 60초 이후 로그 횟수는 별도 실기기 사용 게이트다.

## 2026-09-06 SLP906C001 iPhone 수면 fallback 회귀

- strict 수면 결과가 없을 때만 `PhoneSleepFallbackEngine`을 연결하고, 화면 원본이 비거나 백그라운드 표본 간격이 긴 iPhone 기록을 보완하도록 수정했다. HealthKit·Watch 수면과 겹치는 후보는 기존 차단 규칙을 유지한다.
- TaptionActivityEngine 14/14와 앱 타깃 집중 회귀 2/2(수면 fallback·날짜 task)를 실패·스킵 없이 통과했다: `/private/tmp/SLP906C001-focused-r2.xcresult`.

## 2026-09-06 DAT906L001 날짜 데이터 재조회 지연

- 실기기 로그에서 날짜 로드 `snapshot_wait_ms` 4~9초의 대부분이 `sensor_ms` 5~8초였고, source fingerprint 변경만으로 raw 센서 아카이브 전체를 다시 읽는 경로가 원인이었다: `/private/tmp/DAY906L001-current-iphone.jsonl`.
- raw digest가 유효한 메모리·materialized day readings를 재사용해 현재 source만 재투영하고, raw 불일치·불완전 때만 센서 전체 조회로 fallback한다. 재사용 경로는 `reprojected_memory_raw`·`reprojected_database_raw` 로그로 구분한다.
- source 변경·강제 재로드 회귀 2/2, 30일 cold/warm 날짜 조회 성능 1/1, 실패·스킵 0이다. p95는 `33.542666ms`/`0.04725ms`다: `/private/tmp/DAT906L001-tests-r2.xcresult`, `/private/tmp/DAT906L001-p95.xcresult`.

## 2026-09-06 SEC906D001·SEC906K001·SEC906R001·SEC906C001·SEC906W001 백업·입력 경계 회귀

- 백업 파일·CloudKit payload 크기 제한, PIN 실패 상태 영속화, AAD 메타데이터 인증, 문서 복구 키 기기 이전, Watch/HealthKit route·배열 상한과 confirmation token 검증을 반영했다.
- 보안 회귀 3/3와 Watch query 22/22, 총 25/25·실패 0·스킵 0 및 Simulator Debug build가 통과했다: `/private/tmp/SEC906-final-derived/Logs/Test/Test-TaptionPlan-2026.09.06_14-12-59-+0900.xcresult`.
- iPhone 14 Pro에 최신 수정본을 서명 빌드·설치·launch하고 `com.taption.plan 1.0 (137)` readback까지 확인했다: `/private/tmp/DATE906-final-device-build-r2.log`, `/private/tmp/DATE906-final-install-r2.json`, `/private/tmp/DATE906-final-launch-r2.json`. Watch 원본 수신과 일반 Watch command capability는 별도 게이트로 남긴다.

## 2026-09-06 SEC906P002 HealthKit 자동 추정 source 경계

- HealthKit raw import/provenance는 보존하면서 자동 연속 추정은 Apple Health/Taption source bundle allowlist로 제한했다. 사용자 입력 기록은 별도 명시적 기록으로 유지한다.
- 다른 앱 source의 연속 심박값이 자동 actual을 만들지 않는 회귀를 포함해 `HealthKitIntegrationTests` 21/21 통과, 실패·스킵 0이다: `/private/tmp/SEC906P002-health-derived/Logs/Test/Test-TaptionPlan-2026.09.06_14-46-36-+0900.xcresult`.

## 2026-09-06 BKP906C001 자동 백업 재시도 회귀

- 최근 성공 또는 iCloud 계정 불가 실패 뒤 1시간 동안 포그라운드 자동 백업을 건너뛰고, 경계 시각부터 다시 허용하는 회귀 1/1을 통과했다: `/private/tmp/BKP906C001-focused.xcresult`.
- 수동·00:00 백업 경로는 변경하지 않았고 암호화·무결성·복원 회귀 50/50, 실패·스킵 0을 확인했다: `/private/tmp/BKP906C001-security.xcresult`.

## 2026-09-06 ASC906R001 판매 상태 readback

- API readback에서 앱 버전 `1.0`은 `PREPARE_FOR_SUBMISSION`, build `137`은 `VALID`·미만료이고 Internal 그룹 build 관계에 포함됐다. 그룹 테스터는 1명이며 review submission은 0건이다.
- Pro 상품은 `READY_TO_SUBMIT`, 미국 `USD 9.99`, 175개 지역, 현지화 2건과 심사 이미지 `COMPLETE`다. 버전 한국어 메타데이터와 iPhone 6.7형 스크린샷 2장도 존재·`COMPLETE`다: `/private/tmp/ASC906R001-live.r2SanN`.
- 심사 연락처·version submission·앱 판매 지역 resource·첫 IAP 연결과 API 밖의 Paid Apps Agreement 확인은 남은 외부 게이트다.

## 2026-09-06 DIG906C001 중복 raw 캐시 회귀

- 같은 raw를 다시 append해도 신규 receipt 0건·digest 메모리 캐시 1건 유지·digest 불변임을 집중 회귀 1/1로 확인했다. TaptionPlanCore 전체 52/52도 실패·스킵 없이 통과했다: `/private/tmp/DIG906C001-core-r3.log`, `/private/tmp/DIG906C001-core-full-r1.log`.
- iOS·Widget·Watch·Watch Widget을 포함한 generic iOS Debug build가 통과했다: `/private/tmp/DIG906C001-ios-device-build-r1.log`. 최초 dual-architecture Simulator build는 코드 오류가 아닌 디스크 부족으로 중단됐고, 이번에 생성한 DerivedData와 사용되지 않던 Taption Plan DerivedData만 정리한 뒤 device build로 재검증했다.

## 2026-09-06 MAT906C001 중복 Watch 날짜 캐시 회귀

- 변경 없는 Watch 요약·가속도 재전송 뒤에도 materialized day가 남고 raw event count가 각 저장소 1건으로 유지되는 집중 회귀 2/2를 통과했다: `/private/tmp/MAT906C001-focused.xcresult`.
- `SensorDayStoreTests` 전체 41/41, 실패·스킵 0이며 30일 날짜 조회 성능 회귀와 Debug 앱·Widget·Watch 빌드도 통과했다: `/private/tmp/MAT906C001-store-suite.xcresult`.
- iPhone 14 Pro에는 deep/strict codesign을 통과한 일반 Debug `1.0 (137)` 설치와 developer app 버전 readback까지 완료했다. 기기가 잠겨 launch는 iOS에서 거부됐으며 실제 날짜 전환 체감과 함께 잠금 해제 뒤 확인한다: `/private/tmp/MAT906C001-iphone-install.json`, `/private/tmp/MAT906C001-iphone-launch.log`.

## 2026-09-06 DAY906L001 날짜 로딩 성능

- iPhone 14 Pro(iOS 26.6.1)에서 legacy/envelope 복구, migration, 불완전 projection, 캐시 무효화·축출과 30일 성능 집중 XCTest 12/12를 실패·스킵 없이 통과했다: `/private/tmp/DAY906L001-iphone-tests-r14.xcresult`.
- 실기기에서 최대 `78,239ms`였던 센서 조회는 pre-canonical JSON 2,346건의 반복 외부 복구와 실패한 migration 재시도가 원인이었다. SQLite `REAL` 시각의 1 ULP 왕복 차이 회귀를 포함해 수정했고 migration `25일`·iPhone `153,480건`·Watch `910건` 완료를 로그로 readback했다: `/private/tmp/DAY906L001-fixed-iphone-r6.jsonl`.
- 실기기 30일 cold/warm p95는 `39.534583ms`/`0.010958ms`, migration 이후 후속 지도 날짜 로드는 `277~577ms`, snapshot은 `179~443ms`다. TaptionPlanCore 51/51도 통과했다: `/private/tmp/DAY906L001-core-tests-r2.log`.
- XCTest 주입물을 제거한 일반 Apple Development Debug `1.0 (137)`을 다시 빌드·deep/strict codesign·설치·launch하고 앱 PID `14347`을 readback했다: `/private/tmp/DAY906L001-iphone-build-r9.log`. 실제 손가락 체감은 별도 물리 게이트다.
- 정본 snapshot 전 stale 지도 캐시 게시 차단, raw 일자 revision 재조회, 복원 부분쓰기 방지와 60/30Hz 카메라 projection 회귀 8/8을 실패·스킵 없이 통과했다: `/private/tmp/DAY906L001-followup-r3.ZyrSYM/focused.xcresult`.
- 최신 일반 Debug `1.0 (137)`은 테스트 번들 0개·deep/strict codesign·iPhone 설치·developer app 버전 readback·launch PID `14486`을 통과했다. Debug dylib SHA-256은 `58e2719718ff44e3e1770709710a7219ac0579a77e71926939c55f8f89337726`이며 증적은 `/private/tmp/DAY906L001-iphone-followup.zeZ8iP`다.
- 최신 실기기 로그 4,040건은 일자 snapshot 204회 중 DB cache 1회·재생성 109회, 지도 cache 거부 89회(`source_revision_mismatch` 69회·`source_updated_at_mismatch` 20회)를 보였다. 지도 날짜 로드 p95는 `1,845ms`였다: `/private/tmp/DAY906L001-live-log-r1/attachments/ED73066A-9479-4D4D-96A6-CC04E4238F71.json`.
- 전역 실행 revision 대신 해당 날짜 내용 fingerprint와 raw digest를 사용하도록 수정한 뒤 iPhone 날짜 저장·migration·cache·Watch 회귀 42/42와 기존 payload 호환 Simulator 회귀 8/8을 실패·스킵 없이 통과했다. 30일 cold/warm p95는 `38.536208ms`/`0.052541ms`다: `/private/tmp/DAY906L001-regression-r3/regression.xcresult`, `/private/tmp/DAY906L001-compat-r7/compat.xcresult`.
- 테스트 번들 없는 최신 Debug `1.0 (137)`을 deep/strict codesign·설치하고 developer app 버전 readback·launch PID `14690`을 확인했다. Debug dylib SHA-256은 `fe4b7a8a561e87f38e1aa7201bfd7b86f4ae8941345c43ba41828f25557abe2d`이며 증적은 `/private/tmp/DAY906L001-iphone-final2.9Jm4eN`이다. 실제 날짜 전환 손가락 체감은 별도 물리 게이트다.

## 2026-09-06 IAP905G002 StoreKit 실기기 회귀

- iPhone 14 Pro(iOS 26.6.1) 최초 실행에서 상품 조회·검증 구매 결과는 성공했지만 구매 직후 entitlement가 아직 반영되지 않아 1/1 실패했고, 검증 거래 완료가 UI 잠금 해제보다 앞선 결함을 확인했다: `/private/tmp/IAP905G002-iphone.ebJ0XY/storekit.log`.
- 구매 상태를 먼저 적용한 뒤 거래를 완료하고, 이미 current entitlement가 있으면 인증 없이 복원하도록 수정했다.
- 수정본 StoreKit 집중 1/1과 상거래 잠금·14일 체험·시계 역행·상품형·철회·구매·외부 구매 인식·복원 10/10이 실패·스킵 0으로 통과했다: `/private/tmp/IAP905G002-iphone-r2.S0jnmI/storekit.xcresult`, `/private/tmp/IAP905G002-commerce-r3.8ddFUJ/commerce.xcresult`.
- 최신 전체 소스의 iPhone clean Debug build·설치·launch와 앱 `1.0 (137)`, PID `13950` readback까지 통과했다: `/private/tmp/IAP905G002-iphone-build-r4.log`.
- entitlement가 실제로 누락된 계정의 강제 `AppStore.sync()`는 시스템 계정 인증이 필요한 별도 수동 게이트다.

## 2026-09-06 DEV903V001 iPhone·Watch 실기기 확인

- iPhone 14 Pro(iOS 26.6.1)에 최신 Apple Development Debug `1.0 (137)`을 빌드·설치·launch했고 앱 프로세스 PID `13362`와 버전을 readback했다. 빌드·서명 증적은 `/private/tmp/DEV903V001-iphone-settings-r1.log`이며 Debug dylib SHA-256은 `7bd3355fa7bcebfa9c47d087d072fb882563e2f8c75d23e192583a67b184ec06`이다.
- 교체 전 설치돼 있던 `1.0 (137)`도 launch했지만 설치 provenance를 TestFlight로 확정하지 않았으므로, 최신 개발자 설치와 TestFlight 클라이언트 설치를 같은 PASS로 합치지 않는다.
- 실제 iPhone에서 날짜 ±1일·±7일 이동, 지도 +/-와 한 손가락 pan, 권한 완료 상태에서 온보딩 비노출을 확인했다. 직전 동일 지도·핀치 코드의 물리 iPhone 집중 XCTest는 3/3 통과·실패/스킵 0이다: `/private/tmp/DEV903V001-iphone-focused-r1.xcresult`.
- Watch 자동 가져오기·가속도 수집·모든 권한 승인은 비활성 레거시 설정에만 있어 접근 불가였고, 현재 지도 설정에 기존 `SettingsView` 진입점 하나를 연결했다. 변경 소스의 iPhone 빌드·설치·launch는 통과했지만 iPhone Mirroring 자동 클릭이 원격 화면에 전달되지 않아 새 버튼과 실제 두 손가락 pinch는 물리 터치 미확인이다.
- Apple Watch SE에는 Debug `1.0 (137)`을 설치했고 iPhone의 최근 Watch 접촉 시각 갱신을 확인했다. Watch 앱 launch는 `Navigation away from clock is not allowed due to one or more active system states`로 거부돼 화면·센서 실수신·수면 반영은 미확인이다.
- `xctrace` Time Profiler는 연결된 iPhone을 인식했지만 boot 대기 timeout으로 trace를 만들지 못했다. 장시간 발열·배터리와 TestFlight build 137 클라이언트 provenance/launch는 계속 별도 게이트다.

## 2026-09-06 ALG904A001 전체 기록 경로 회귀

- Swift Package는 TaptionActivityEngine 14/14, TaptionRouteEngine 20/20, TaptionPlanCore 51/51, TaptionPlanEngine 1/1—총 86/86 통과했다.
- Watch 원본 제한 재시도·HealthKit 수면 delta·손상 센서 cache·POI 삭제 fence 등 집중 XCTest 7/7 통과: `/private/tmp/ALG904A001-app-r3.9gBYjO/focused.xcresult`.
- 전체 XCTest·Swift Testing은 1,031건 중 1,030 passed·1 skipped·0 failed다: `/private/tmp/ALG904A001-full-r2.ByyHu3/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 StoreKit 시스템 오류다.
- 전체 회귀가 검출한 대중교통 예상경로 누락은 근거가 있는 버스·지하철·열차·선박에 저속 endpoint 예외를 적용한 뒤 집중 1/1과 전체 회귀로 재검증했다: `/private/tmp/ALG904A001-route-r1.T6fuAE/route.xcresult`.
- generic iOS·watchOS Debug와 iOS static analyze는 모두 exit 0이다: `/private/tmp/ALG904A001-build-r1.TPiSR6`. 앱 30일 load p95는 cold `32.998416ms`, warm `0.006625ms`다.
- 최신 iPhone Simulator 앱 설치·launch PID `73497`을 readback했고 안정화 뒤 5회 CPU `0.0%`, RSS `187,920~187,984KiB`였다. 이는 실기기 장시간 발열·배터리 검증이 아니다.
- 보안 diff scan은 17/17 변경 파일을 검토하고 malformed timestamp, Watch raw replay, 삭제 후 POI 게시 후보를 수정·검증해 최종 보고 대상 0건으로 완료했다: `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-jOiTAE/taption-plan/af7352832651ca69d5863cff8dc36b0c8d2dbdc0_20260905T162732Z_ehr2iwgg/report.md`.

## 2026-09-06 ASC906A001 App Store 판매 초안 readback

- App Store version `1.0`과 build 137의 exact ID 관계, `VALID`·미만료·`APP_STORE_ELIGIBLE`·비면제 암호화 사용 `false`를 API로 확인했다.
- 공개 개인정보처리방침·지원 문서 HTTP 200과 한국어 설명·키워드·부제·지원/개인정보/개인정보 선택 URL·저작권·생활/건강 및 피트니스 카테고리·제3자 콘텐츠 선언의 저장값을 재조회했다.
- 연령등급 전 문항을 채웠고 175개 지역 결과는 9+ 172개·한국 전체이용가 1개·10+ 1개·12+ 1개다.
- 앱 버전은 계속 `PREPARE_FOR_SUBMISSION`이고 review submission은 0개다. 개인정보 없는 iPhone 6.7형 스크린샷 2장의 asset `COMPLETE`와 세트 2건을 API로 확인했다. 심사 연락처·판매 지역·앱 개인정보 수집 답변·Paid Apps Agreement·DSA/비규제 의료기기 선언·첫 IAP 웹 추가는 미완료다.
- 증적: `/private/tmp/IAP905G002-api.3i778W`, `/private/tmp/ASC906A001-screenshot.sGrWXW`.

## 2026-09-05 BAK905I001 실제 iCloud 백업 복호화

- iCloud의 8·9월 snapshot·raw 파일을 실제 32바이트 계정 복구 키로 AES-GCM key unwrap·payload decrypt하고 LZFSE·JSON v1·월/generation 쌍까지 검증했다: `/private/tmp/BAK905I001-live.5vfwUn/live-backup-readback.log`.
- 8월은 route 2,516건, raw reading 15,369건·envelope 12,876건이며 9월은 route 2,728건, raw reading 7,403건·envelope 19,132건이다. 네 payload 모두 무결성·복호화·압축 해제가 정상이다.
- 좌표·건강값·복구 키는 출력하지 않았고 일회성 검증기 소스·바이너리는 삭제했다. 앱 UI에서 복원 적용·merge한 뒤 데이터 readback하는 단계는 실기기 미완료다.

## 2026-09-05 BAK905H010·REL905H011 raw 실패 롤백·TestFlight build 137

- 월간 raw 저장 뒤 snapshot 커밋이 실패할 때 직전 정상 raw가 덮어써지던 결함을 수정했다. 병합 중 이미 읽은 archive를 되돌리며, 이전 파일이 없으면 미커밋 raw만 삭제한다.
- 집중 회귀 1/1, `SecurityBackupCoreTests` 50/50, 앱 전체 1,027건 중 1,026 passed·1 skipped·0 failed다: `/private/tmp/BAK905H010-focused.K2HmMB/focused.xcresult`, `/private/tmp/BAK905H010-focused.K2HmMB/security-suite.xcresult`, `/private/tmp/BAK905H010-focused.K2HmMB/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 StoreKit 시스템 오류다.
- 배포 소스 `a6e770f64491e97896136a1b7692620bf6c0c62b`에서 앱·iOS Widget·Watch 앱·Watch Widget을 모두 `1.0 (137)`로 archive/export했다. archive·IPA deep/strict codesign, privacy manifest 5개, Apple Distribution, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`와 Apple 서버 사전 검증을 통과했다.
- archive는 `/private/tmp/REL905H011-release.nFPbOf/TaptionPlan-1.0-137.xcarchive`, IPA는 `/private/tmp/REL905H011-release.nFPbOf/Export/TaptionPlan.ipa`, SHA-256은 `18e5516b30726c1ba7862907062c7421ef743fff7f12165bf0e40f0b0a07d405`다.
- Delivery/build UUID `1b26a479-4bd6-49df-bda2-2f1bf1f0d28a`는 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다. `TP Taption Plan 내부 테스트` 추가 후 build 137 포함·그룹 빌드 98개·내부 테스터 1명 `INSTALLED`를 API readback했다.
- TestFlight 클라이언트 build 137 설치·launch·실제 백업 복원·터치·장시간 발열/배터리는 별도 미완료 게이트다.

## 2026-09-05 BAK905H008·REL905H009 raw 복원·TestFlight build 136

- raw를 생략한 포그라운드 스냅샷 저장이 새 generation ID로 월간 파일을 덮어써 기존 raw 백업을 복원 대상에서 제외할 수 있던 결함을 수정했다. 같은 달의 기존 generation ID를 보존하고 포그라운드 경로는 스냅샷 저장 API를 사용한다.
- 원본 백업 연속성 집중 회귀 1/1, `SecurityBackupCoreTests` 50/50, 앱 전체 1,027건 중 1,026 passed·1 skipped·0 failed다: `/private/tmp/BAK905H008-focused.b6Zr0b/result.xcresult`, `/private/tmp/BAK905H008-focused.b6Zr0b/security-suite.xcresult`, `/private/tmp/BAK905H008-focused.b6Zr0b/full.xcresult`. skip은 iOS 26.5 Simulator의 기존 StoreKit 시스템 오류다.
- 실제 iCloud의 `2026-09.taptionbackup`과 `2026-09.rawsensorbackup`은 JSON v1, 암호화 payload·PIN/account wrapped key 포함, 저장 digest와 암호문 SHA-256 일치를 확인했다. 실기기 PIN 복호화·복원 적용은 확인하지 않았다.
- 배포 소스 `f76af5a9dd23e880f00c9d3b5cf2b6b173efe83b`에서 네 번들을 `1.0 (136)`으로 archive/export했다. archive·IPA deep/strict codesign과 네 privacy manifest, 배포 IPA의 Apple Distribution·`beta-reports-active=true`·iCloud `Production`·`get-task-allow=false`를 확인했다.
- IPA SHA-256은 `32486649b566c61a3270ee0424e8d99a50a4c176c3200ea9f0edb1c24c639b86`; Delivery/build UUID는 `85cabd56-8654-4124-b660-9e8793fe4853`이며 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다.
- `TP Taption Plan 내부 테스트`에 build 136을 추가했고 API readback에서 build 136 `VALID`, 그룹 빌드 97개, 내부 테스터 1명을 확인했다.
- TestFlight 클라이언트 build 136 설치·launch·실제 백업 복원·터치·장시간 발열/배터리는 별도 미완료 게이트다.

## 2026-09-05 REL905H007 TestFlight build 135

- 배포 소스 `1ca699e5f0da06c18dd453b31c688c5b38405a31`에서 앱·iOS Widget·Watch 앱·Watch Widget을 모두 `1.0 (135)`로 archive/export했다.
- 전체 앱 테스트는 1,027건 중 1,026 passed·1 skipped·0 failed, 집중 회귀 6/6, 성능 회귀 4/4이며 iOS·watchOS Debug와 앱 정적 분석을 통과했다. skip 1건은 iOS 26.5 Simulator의 `SKInternalErrorDomain Code 3` StoreKit 시스템 결함이다.
- archive와 IPA의 deep/strict codesign, 네 번들의 privacy manifest를 확인했다. 배포 IPA는 Apple Distribution, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`; SHA-256은 `f2f5ef3b106fb37c480b1e365888fe66844c4c111c0d06b990b9c7bc110807e3`이다.
- App Store Connect 업로드에 성공했다: Delivery/build UUID `365a5ef7-dfda-447f-8b4c-3c807f1ef37e`, `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `PROCESSINGSTATE: VALID`, `expired=false`.
- `TP Taption Plan 내부 테스트`에 build 135를 추가했고 API readback에서 build 135 `VALID`·미만료, 그룹 빌드 96개, 내부 테스터 1명을 확인했다.
- TestFlight 클라이언트의 build 135 실기기 설치·launch·실제 화면/터치·장시간 발열/배터리는 별도 미완료 게이트다.

## 2026-09-05 DEV905H006 iPad 최신 소스 설치

- iPad Pro 12.9-inch 6세대(iPadOS 26.6.1, 유선 연결, 개발자 모드)에 최신 dirty 소스의 iOS 실기기 앱·XCTest 번들을 Apple Development로 서명해 `build-for-testing`했다: `/private/tmp/DEV905H006-ipad.wmSSIl/build-for-testing.log`.
- 앱과 내장 Watch·Widget 서명 검증 후 `com.taption.plan` 1.0(134)을 설치했고 기기 앱 목록에서 같은 버전을 readback했다.
- 설치 후 실행은 `FBSOpenApplicationErrorDomain Code 7 / Locked`로 거부됐다: `/private/tmp/DEV905H006-ipad.wmSSIl/launch.log`. 잠금 해제 전에는 첫 화면·StoreKit 실거래 XCTest·터치 판정을 통과로 처리하지 않는다.
- 설치 뒤 재생성 가능한 이 프로젝트 전용 DerivedData는 제거했고 테스트·설치 로그는 보존했다.

## 2026-09-05 REL905H005 판매 상태 API 재검증

- App Store Connect API에서 Taption Plan 앱과 TestFlight 1.0(134) `VALID`·미만료, `TP Taption Plan 내부 테스트` 연결, 내부 테스터 1명을 다시 확인했다.
- `com.taption.plan.pro`는 비소모성 `READY_TO_SUBMIT`; 한국어·영어 현지화, 미국 기준 `USD 9.99`, 한국·미국 포함 175개 지역, 새 지역 자동 추가, 1206×2622 심사 이미지 `COMPLETE`, 상품 버전 1 `PREPARE_FOR_SUBMISSION`이다.
- 현재 API 키는 앱 버전 조회를 403으로 거부하고 계약 목록은 공개 API 경로가 없어, Paid Apps Agreement와 앱 버전 상품 연결은 App Store Connect 브라우저 재인증 게이트로 유지한다.

## 2026-09-05 OPT905H004 다방면 코드 리뷰·후속 최적화

- 지도 시각·지도/데이터 런타임·상거래/Watch 경계를 세 갈래로 검토했으며 P0는 없고 확인된 P1을 모두 최소 수정했다.
- 불완전 일자 projection은 저장·메모리 캐시하지 않아 다음 조회에서 복구하며, 원본 revision 변경으로 중단된 legacy migration은 최신 revision으로 다시 예약한다.
- 날짜 전환 시 3일 전체 공급자 강제 조회를 제거하고 선택 일자와 overnight 수면 구간만 증분 조회한다. 지도 로드 key에도 projection revision을 포함해 stale 화면을 막았다.
- 실제 경로의 선택 opacity를 두 지도 렌더러에 보존하고 MapKit은 변경된 polyline만 교체한다. gesture 시작 시 최신 pinch·pan recognizer를 연결하고 native 현재위치 점은 숨겨 같은 좌표의 졸라맨 하나만 표시한다. 집 마커도 기존 평면 SF Symbol 체계로 통일했다.
- 유료 권한 확인 전 iPhone 데이터 변경을 차단하고 Watch payload에 잠금 상태를 전달해 가속도·건강 동기화·위치·운동을 중단한다. 구형 Watch payload는 선택 필드로 계속 decode한다.
- 신규 집중 회귀 6/6과 성능·경로 회귀 4/4가 통과했다: `/private/tmp/PRD904A001-p1-focus-r3.cIOcqn/result.xcresult`, `/private/tmp/PRD904A001-p1-perf.ErbfPz/result.xcresult`. 앱 30일 load p95는 cold `33.154708ms`, warm `0.007334ms`다.
- 최신 전체 검증은 총 1,027건 중 1,026 통과·실패 0·스킵 1이다: `/private/tmp/OPT905H004-full.9nXS8G/result.xcresult`. 스킵은 iOS 26.5 Simulator의 기존 StoreKit `SKInternalErrorDomain Code 3`에만 한정된다.
- Watch 단독 Debug build와 전체 앱 정적 분석도 exit 0이며, iPhone·Watch 실제 센서 수신과 장시간 발열·배터리·pinch는 `DEV903V001` 실기기 게이트로 유지한다.

## 2026-09-05 ALG905H003 전체 알고리즘·성능·배터리 리뷰

- 센서·HealthKit·Watch·행동·지하철·경로·캘린더·iCloud 백업을 병렬 검토하고 확인된 정확도·성능 결함을 최소 수정했다.
- GPS 정밀도 기준과 지하철 연속 관측 조건을 수집·복원 경로에 동일 적용했고, 조밀한 지하철 후보 생성은 인접 최단 경로를 한 번만 계산하도록 바꿨다. HealthKit 무변경 foreground 조회 간격은 15분으로 늘렸다.
- 예상 경로는 실제 정밀 경로가 완성되면 도착 시각 이후에도 제거하고 stale 생성 경로를 재사용하지 않는다. 재생 WBS leg는 분 단위 색인으로 조회하며 정확한 분 경계와 DST 23·25시간을 회귀 검증했다.
- 캘린더 부분 응답은 선택·기존 일정을 보존하고 최신 날짜 요청만 100ms debounce 후 재조회한다. iCloud 월별 raw→snapshot 저장에 같은 generation ID를 부여하고 같은 세대만 복원하며 손상 파일은 파일 단위로 격리한다.
- Watch ambient drain은 요약마다 전체 가속도 배열을 재필터링하던 경로를 순차 커서 O(N+M)로 바꾸고, 가속도 청크·요약을 SQLite 한 번에 저장한다. 운동 중 표본 수 UI 갱신은 25Hz에서 1Hz로 줄였으며 행동 창이 전진할 때만 보존 배열을 정리한다.
- 집중 회귀는 센서·지하철 6/6(`/private/tmp/SHE905H001-r2.sSQPZB/result.xcresult`, 96역 조밀 경로 0.831초)과 시간·백업 경계 3/3(`/private/tmp/EDGE905H001-r5.ByXdTJ/result.xcresult`) 통과했다.
- Swift Package 회귀는 Core 50/50, Activity 12/12, Route 18/18, PlanEngine 1/1로 총 81/81 통과했다.
- 최종 전체 XCTest는 1,024 통과·0 실패·1 건너뜀, 총 1,025건이다: `/private/tmp/ALG905H003-final.UCNk7Q/result.xcresult`. 건너뜀 1건은 iOS 26.5 Simulator의 기존 `SKInternalErrorDomain Code 3` StoreKit 시스템 결함이다.
- generic iOS Simulator Debug build, Swift parse, `git diff --check`, 단일 아키텍처 Xcode 정적 분석이 모두 통과했다. iPhone·Watch 장시간 발열·배터리와 실제 HealthKit·Watch 수신은 `DEV903V001` 실기기 게이트로 유지한다.

## 2026-09-05 TRK905H001 자동 추적 세션 복원

- 자동 감지 수집기는 걷기·달리기를 `walking`·`running`으로 저장하지만 AppModel은 `automatic` 종류만 자동 세션으로 재구성해, 재시작 뒤 자동 종료가 빠지고 고정밀 센서가 계속 실행될 수 있었다.
- `SensorReading` 원본에 선택형 자동 감지 여부를 저장하고 이를 복원에 우선 사용했다. 구형 원본은 기존 `automatic` 규칙으로 읽으며 수동 걷기는 수동으로 유지한다.
- 자동 걷기·수동 걷기·구형 자동 세션 집중 XCTest 1/1 통과, 실패·스킵 0: `/private/tmp/TRK905H001.yGj1cw/result.xcresult`. Swift parse와 `git diff --check`도 통과했다.

## 2026-09-05 WCM905H001 Watch 명령 시각 검증

- Watch 센서·건강 payload와 달리 일정 명령에는 수신 시각 상한이 없어, 크게 틀어진 Watch 시계가 미래의 실행·완료·연기 기록을 만들 수 있는 누락을 확인했다.
- 기존 5분 clock-skew 정책을 명령 decode 직후와 중복 ID 저장 전에 적용했다. 지연 도착한 과거 명령은 그대로 허용하고 5분을 넘는 미래 명령만 거부한다.
- `WatchDeletionPayloadTests` 10/10 통과, 실패·스킵 0: `/private/tmp/WCM905H001.ShgOVY/result.xcresult`. Swift parse와 `git diff --check`도 통과했다.
- 현재 CoreDevice readback은 iPad 연결, iPhone·Apple Watch unavailable이다. iOS 26.6.1 iPad StoreKit 실기기 XCTest는 빌드·서명 뒤 기기 잠금으로 실행 직전 중단했으며, 실제 Watch 명령 송수신도 기존 실기기 게이트로 유지한다.

## 2026-09-05 ALG904A001·CAC905H001·EXP905H001·WDI905H001·SEN905H001 추가 리뷰

- 변경 60개 소스·테스트 파일을 저장소·센서/HealthKit/Watch·지도/경로/UI 세 영역으로 병렬 검토했다. 보안 diff scan은 coverage `complete`, 보고 대상 취약점 0건으로 완료됐다: `/private/var/folders/q1/0p9tcvnx7yx5l12y55zm4tdm0000gn/T/codex-security-scans-kQTEid/taption-plan/9684e36b705bb0acfdea29298a04397951e403e8_20260905T092546Z_mfy6cpty/report.md`.
- 성능·배터리 보정은 raw digest 캐시를 64일 LRU로 제한하고, 센서 분석을 날짜별 pending·최대 120초 묶음으로 합치며 자정 경계 시작·종료일을 모두 처리한다. DB 읽기 실패 날짜는 제거하지 않고 동일 cadence로 재시도한다.
- Watch 삭제는 성공 generation을 Watch 로컬에 보존하고 실시간·보장 전송의 중복 요청을 직렬화했다. 삭제 후 재생되는 과거 명령, 저장 중 삭제 fence, 미래시각 건강·가속도·행동·확인 payload와 내부 수면·표본·경로를 차단하거나 경계에서 절단한다.
- 구형 Watch 수면 합계는 삭제 경계 뒤 구간 근거가 없으면 제거하고, 수신 허용 상한을 걸친 수면 구간은 유효 부분만 남겨 재계산한다. Watch 최종 요약과 가속도 청크는 자정을 넘으면 양일 분석을 직접 예약한다.
- 개인 기록 내보내기는 앱 전용 임시 폴더의 이전 파일을 지우고 공유 종료 시 현재 파일도 삭제하며, 전체 기록·위치 포함 범위와 파일명을 실제 payload에 맞췄다.
- TaptionPlanCore 50/50과 내보내기 집중 회귀를 통과했다. 최신 Watch 삭제·미래시각·수면 9건, 다중 날짜 분석·DB 실패 재시도 2건은 공용 빌드 락 안에서 11/11 통과했고 iOS 앱·embedded Watch Debug 산출물을 함께 빌드했다: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.09.05_19-49-25-+0900.xcresult`.
- Swift parse와 `git diff --check`를 통과했다. 실물 Watch 삭제·센서 수신·수면 반영, iPhone 장시간 발열/배터리와 지도 두 손가락 pinch는 자동 검증 범위 밖이라 기존 실기기 게이트로 유지한다.

## 2026-09-05 PAY905A001 유료 상품 준비

- App Store Connect API 사전 조회에서 앱 `6797370230`의 앱 내 구입은 0건이었고, TestFlight build `134`는 `VALID`·만료 아님·내부 그룹 1개 연결 상태였다.
- `com.taption.plan.pro`를 비소모성 상품으로 생성했다: 상품 ID `6808848628`, 이름 `Taption Plan Pro Lifetime`.
- 한국어·영어 현지화 2건, 미국 기준 소비자가 `USD 9.99`·개발자 수익 `USD 8.49`, 신규 지역 자동 제공과 175개 판매 지역(미국·한국 포함)을 API readback했다.
- 심사용 구매 화면 `/private/tmp/PRD904A001-iap-review.png`를 업로드했고 asset 상태 `COMPLETE`, 심사 메모 저장 후 상품 상태 `READY_TO_SUBMIT`을 readback했다.
- 로컬 StoreKit 구성 가격도 `0.99`에서 `9.99`로 맞췄고 product ID·상품 타입·가격 JSON 검증과 `git diff --check`를 통과했다.
- StoreKitTest 자동검증은 실제 `Product.products`·`Product.purchase`·`Transaction.currentEntitlements`·`AppStore.sync` 경로를 사용하며, 구성 파일은 테스트 번들에만 포함하고 실기기 테스트 타깃을 앱과 같은 개발팀으로 서명했다.
- Xcode 26.6의 iOS 26.5 Simulator 두 기기에서 CLI·IDE 모두 `SKInternalErrorDomain Code 3` 시스템 결함이 재현돼 해당 runtime만 명시적으로 건너뛴다. 전체 앱 결과는 `988 passed / 0 failed / 1 skipped`, 총 989건이다: `/private/tmp/IAP905G002-full-r2.xcresult`.
- iOS 26.6.1 iPad용 테스트 번들은 서명·빌드됐지만 기기가 잠겨 실제 구매·권한·복원 실행 직전 취소됐다. 잠금 해제 뒤 같은 테스트의 1/1 통과가 남아 있다.
- iPhone 시뮬레이터에서 권한 안내는 전체 건너뛰기 뒤 한 번만 재표시되고 세 번째 실행부터 숨겨짐을 확인했다. 지도 렌더·확대 버튼·16회 날짜 왕복·접근성 XXXL을 확인했고, idle CPU 5회 모두 `0.0%`, 날짜 왕복 20초 평균 `2.55%`·최대 `26.00%`였다.
- 상품 제출은 보류했다. Chrome의 계약 페이지는 `authResult=FAILED` 로그인 화면으로 열렸고 자격 증명은 입력하지 않았다. Paid Apps Agreement 활성 상태, sandbox/TestFlight 상품 조회·구매·복원, 앱 버전 연결·심사 제출은 별도 외부 게이트다.

## 2026-09-05 ALG904A001·PRD904A001 코드 리뷰·성능·배터리 회귀

- iCloud 원본 readback: actual 39건, travel 4,667건/33일, weather 5,675건, calendar 104건, floor 1,688건, raw reading 7,403건, envelope 19,132건이었다. Watch acceleration·Watch sleep 원본은 0건이고 당시 `health_enabled=false`였다.
- 날씨 envelope 13,673건은 실제 관측 시각 97개·fetch 232회·위치 bucket 53개로 중복이 컸다. raw 압축 해제 예상 크기 `146,067,067 bytes`가 기존 64MiB 제한을 넘었고, 일자 DB fallback이 이동 4,667건 전체를 후보화했다.
- 확정 결함 수정: MapKit recognizer 재부착·1Hz 탐색 제한, 일자 캐시의 불필요한 강제 재생성, timestamp-only 전체 projection 무효화, 파생 projection 누적, 동기식 진단 로그, Watch raw 이중 저장 일부 실패 readback, legacy Watch 가속도 이관 누락, cold background wake 중복 센서·Watch 소유, HealthKit callback burst·query 취소 누락·부분 실패 은폐, 이동 후보 task 고착, background 날씨 작업, Watch 자동 동기화 burst.
- 저장·전력 결함 수정: 다중 저장 실패 rollback, 전역 삭제 fence, 삭제 뒤 새 세대 빈 스냅샷 저장, raw 내부 checksum·byte count 검증과 안정적 identity, 첫·마지막 즉시 저장을 포함한 최대 5개/5초 센서 batch, background refresh 단일 저장, 동일 파생 raw 멱등 저장, Watch 로컬 archive 우선 보존, iPhone sensor generation·실패 batch 재큐잉, Watch purge 중 지연 저장 취소, 백업 부분 삭제 시 성공일 보존.
- 추가 최적화: 일시적 빈 캘린더 응답에서 선택·cache 보존, 권한 재허용·EventKit 변경 시 광역 갱신과 평시 6시간 cadence, background 날씨 cancellation fence, iPhone background wake 기반 Watch 자동 재무장, 과거 날짜의 60초 route polling 중단, Debug frame probe 환경변수 opt-in, 1시간 지난 CloudKit 업로드 임시 파일 정리.
- 알고리즘·복원 수정: 부정확·근사·비정상 GPS를 실제 경로·재생·보행·지하철·예상경로에서 제외하고 긴 공백은 직선 보간하지 않는다. segment-local 증거·역 간격 guard·O(n log n) 겹침 정리, source-safe 복원, Watch purge command·ACK와 지연 저장 fence를 적용했다.
- 날씨 raw는 256MiB 제한과 checksum·byte count 검증을 유지하면서 같은 예보 시각의 최신 revision만 채택하고, 기기 위치를 forecast stream identity에서 제외한 뒤 화면 값 변화만 저장한다. 이 결함은 첫 전체 실행에서 회귀 테스트 실패 1건으로 검출·수정했다.
- 캘린더는 source/timezone/floating/original component·external recurrence occurrence를 보존하고 provider/account/occurrence 중복을 제거했다. SQLite 정본은 유지하며 CSV는 교환용 export/import로만 제한한다.
- 시각 체계 수정: 실제 경로 teal, 예상 경로 red dash, 대중교통 gold를 공통 theme token으로 통일하고 장소·학원 아이콘 및 대중교통 라벨 가독성을 일치시켰다.
- 무결성·성능·스타일 집중 XCTest 9/9, 실패·스킵 0: `/private/tmp/PRD904A001-review-focused-final.xcresult`.
- HealthKit·Watch legacy 집중 XCTest 18/18, 실패·스킵 0: `/private/tmp/PRD904A001-health-storage-focused.xcresult`.
- 캘린더·CloudKit 임시 파일·백업 실패 집중 XCTest 5/5, 실패·스킵 0: `/private/tmp/PRD904A001-followup-focused-v2.xcresult`.
- Swift Package: TaptionPlanCore 49/49, TaptionActivityEngine 12/12, TaptionRouteEngine 18/18, TaptionPlanEngine 1/1—총 80/80 통과. raw digest는 쓰기 변경 시만 무효화하고 다른 SQLite 연결의 commit은 `data_version`으로 감지한다. 최신 30일 day store p95는 cold `5.280917ms`, warm `0.0315ms`다.
- 삭제 fence 활성 중 저장 거부와 해제 뒤 새 세대 저장 성공 회귀 18/18 통과: `/private/tmp/ALG904A001-deletion-focus-r4.S7hOjq/result.xcresult`.
- 임시 DB 격리·30일 로드 집중 XCTest 3/3 통과: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC/focused.xcresult`. 앱 30일 load p95는 cold `51.037208ms`, warm `0.007792ms`다.
- 최신 전체 앱 검증은 XCTest와 Swift Testing 총 1,005건 중 1,004 통과·실패 0·스킵 1: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC/full-final.xcresult`. 스킵은 iOS 26.5 StoreKitTest `SKInternalErrorDomain Code 3` 시스템 결함에만 한정된다. 이 실행의 앱 30일 load p95는 cold `35.755208ms`, warm `0.008375ms`, 이동 4,667건 겹침 정리 평균은 약 `0.007s`다.
- 최신 변경 기준 generic iOS Debug build, generic watchOS Debug build, iOS static analyze가 각각 exit 0으로 통과했다: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC`.
- iCloud snapshot·raw backup·진단 로그에서 HealthKit·Watch·수면 정보와 파생 보고서를 제외하고, 기존 iCloud 건강 로그를 1회 삭제한다. App Group과 `Application Support/TaptionPlan`은 시스템 iCloud 백업 제외 속성을 적용했으며 Simulator에서 `com.apple.metadata:com_apple_backup_excludeItem`을 readback했다.
- 앱·iOS Widget·Watch 앱·Watch Widget에 Required Reason API privacy manifest를 포함해 모두 `plutil` 검증했다. Release archive/export는 `/private/tmp/PRD904A001-release-r1/TaptionPlan-1.0-134.xcarchive`, `/private/tmp/PRD904A001-release-r1/Export/TaptionPlan.ipa`이며 네 번들 모두 `1.0 (134)`, Apple Distribution, Production iCloud, `beta-reports-active=true`, `get-task-allow=false`, deep/strict codesign을 통과했다. IPA SHA-256은 `2680e24aaa97f6a019d8ff7fe95f6f62522e53bef5a5a384276065c1ab34f224`다.
- Swift parse, `git diff --check`, StoreKit JSON 구문 검증을 통과했다. Xcode 설치본에는 별도 `privacytool` 실행 파일이 없어 archive 내 매니페스트 존재·plist 구문·번들 서명으로 검증했다.
- 최신 iPad Simulator 산출물을 재설치·launch해 PID `39271`을 readback했다. 5초 뒤 CPU `5.2%`에서 이후 4회 `0.0%`로 안정화됐고 RSS 약 `263~267MiB`였으며 crash 없이 유지됐다.
- 최신 iPhone Simulator에서 권한 안내의 건강 데이터만 `연결 필요`이고 위치·캘린더는 `연결됨`인 상태를 readback했다. 전체 건너뛰기 후 지도 확대 3회와 날짜 왕복 20회를 실제 UI로 수행해 오늘 화면으로 정상 복귀했고, 이후 CPU 5회 모두 `0.0%`, RSS 약 `300MiB`로 안정화됐다. 화면 증적: `/private/tmp/PRD904A001-digest-cache-r4.JjAEIC/latest-map-clean.png`.
- 자동 검증은 실제 두 손가락 pinch, 장시간 발열·배터리, iPhone/Watch 센서 실수신, Apple·Google·Naver 실제 계정, StoreKit sandbox 및 App Store Connect 판매 상태를 증명하지 않는다.

## 2026-09-05 ALG904A001·PRD904A001 현재 기기 readback

- 최신 dirty 소스의 Apple Development 서명 Debug `Taption Plan com.taption.plan 1.0 (134)`를 iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`)에 설치하고 앱 목록과 실행 중 PID `8297`을 readback했다. 이는 TestFlight 설치가 아니다.
- 앱 시작 시 CloudKit 전용 임시 파일은 `59개·172,184,964 bytes(164.2MiB)`에서 `0개`로 정리됐고, 최신 1시간 파일과 무관 파일 보존은 회귀 테스트로 확인했다.
- iPad Pro(`4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`)에 같은 최신 Apple Development 서명 Debug `Taption Plan 1.0 (134)`를 설치하고 앱 목록에서 버전을 readback했다. 반복 launch는 잠긴 기기에서 `FBSOpenApplicationErrorDomain code 7 · Locked`로 거부되어 실행·화면·터치는 미완료다. Apple Watch(`9229A9F2-B4F1-5A44-ACFA-0E5B00F3B3AF`)는 `unavailable`이다.
- 위 결과는 최신 dirty 소스 설치·프로세스 실행·임시 파일 정리만 증명한다. TestFlight 1.0(134) 설치, 화면·두 손가락 터치, 장시간 발열·전력, 센서 정확도와 Watch 실제 수신·purge ack는 별도 게이트다.

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
- `ARC831A001` 전체 검증: package 65건(`Core` 40, `Activity` 8, `Route` 16, `PlanEngine` 1), 앱 XCTest 848건과 Swift Testing 18건이 모두 통과했고 generic iOS Debug·Release 빌드와 Release archive/export가 성공했다.
- build 121 배포 소스는 `53e18940bbf13459927d23053ad783f0b8431294`; 앱·Widget·Watch·Watch Widget 모두 `1.0 (121)`, Apple Distribution 서명, Production iCloud, TestFlight entitlement, deep codesign을 확인했다. IPA SHA-256은 `3957d7f3800314fc9af6f201a3a4ad3ef20548120f6917072337ef187dffa667`이다.
- build 121 TestFlight 업로드: Delivery UUID `d1cf40bf-7b56-42ef-a7cb-12d82067734c`; upload state `COMPLETE`, 오류·처리 경고 0, App Store Connect `제출 준비 완료`를 readback했다. MapLibre 외부 framework dSYM 미포함은 심볼 업로드 경고이며 앱 업로드는 수락됐다.
- build 121을 `TP Taption Plan 내부 테스트`에 연결했다. 그룹 상세에서 `내부 그룹 · 1명의 테스터 · 82개의 빌드`, 빌드 화면에서 `1.0 (121) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명 노출을 확인했다. 현재 설치 표시는 `1.0 (120)`이며 build 121 설치·실행·실제 화면/터치와 Watch 현장 수신은 미완료다.
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

## 2026-09-01 통합 검증

- `STK901A001`, `PAID831001`, `SUB8310001`, `WAT8310001`, `RTE8310001` 구현과 최종 P0/P1 읽기 전용 재리뷰를 완료했다.
- iPhone 14 Pro 시뮬레이터 전체 XCTest 874건 통과, 실패·건너뜀 0건 (`/private/tmp/taption-manager-final-full-alt.xcresult`).
- `REL901A001` 릴리스 회귀에서 철도 일치 1회만 있는 두 역 차량 이동의 지하철 오탐 경로를 차단했다. 두 역 sparse 복원·catalog 승차 후보는 철도 일치 최소 2회와 25% 비율 또는 연속 지하철 Wi-Fi를 요구하며, 세 역 이상 정합 경로와 Watch 진동·지하 신호 판정은 유지한다.
- `REL901A001` 관련 집중 XCTest 6건 통과, 실패·건너뜀 0건 (`/private/tmp/taption-rel901a001-rail-evidence-v4.xcresult`).
- build 122 최종 iPhone 14 Pro 시뮬레이터 전체 XCTest 876건 통과, 실패·건너뜀 0건 (`/private/tmp/taption-rel901a001-final-full-v3.xcresult`).
- 물리 iPhone 14 Pro에서 지하철 후보·예상경로 중복·Watch receipt 핵심 XCTest 5건 통과, 실패 0건 (`/private/tmp/taption-manager-device-focused.xcresult`).
- 현재 소스의 서명 Debug `1.0 (121)` 빌드·설치 후 앱 목록에서 버전과 빌드 번호를 readback했고, `com.taption.plan` 실행 및 PID `13753`을 확인했다.
- 물리 iPhone 사용은 Taption Cam `8/29 메인 개발`과 상호 메시지로 빈 슬롯을 확인한 뒤 진행했으며, 설치·실행 readback 직후 슬롯을 반환했다.
- 실제 Apple Watch envelope 수신과 설정 화면의 `수신 대기 → 최근 수신` 전환은 Watch가 CoreDevice에서 `unavailable`이라 현장 게이트로 유지한다.
- `REL901A001` 배포 소스는 `865588099a680d100080c891afed3de9cb8e41b0`이며 배포 시 `main`·`origin/main`·원격 main이 일치하고 tracked worktree가 clean이었다.
- iPhone 14 Pro에 build 122 Debug를 설치해 `Taption Plan com.taption.plan 1.0 122`를 readback하고 앱 실행 PID `14952`를 확인했다. Cam에서 반환받은 슬롯만 사용했고 ShotGuide `1.0.0 (57)`과 데이터는 보존했다.
- build 122 archive/export 성공: `/private/tmp/taption-rel901a001-build122/TaptionPlan-1.0-122.xcarchive`, `/private/tmp/taption-rel901a001-build122/Export/TaptionPlan.ipa`. IPA SHA-256은 `ad2bbab7dedee8e7d78eae0da325f6c4a407fd50eb13b64d5af53f85b7c9a309`이며 앱·iOS Widget·Watch·Watch Widget 모두 `1.0 (122)`, Apple Distribution 서명, Production iCloud, TestFlight entitlement, deep codesign을 확인했다.
- build 122 TestFlight 업로드 성공: Delivery UUID `1c4edd59-af22-4bba-a432-13e7778b3a32`; `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `PROCESSINGSTATE: VALID`.
- App Store Connect API에서 build 122 `VALID`, `TP Taption Plan 내부 테스트` 관계 포함, 그룹 빌드 83개, 내부 테스터 1명을 readback했다.
- App Store Connect Chrome 화면에서 `TP Taption Plan 내부 테스트 · 1명의 테스터 · 83개의 빌드`, build `1.0 (122) · 테스트 중 · iOS`를 readback했다. 테스터 화면에는 내부 테스터 1명이 노출됐고 현재 설치 표시는 `1.0 (121)`이므로 build 122 설치로 과장하지 않는다.

### 미완료 게이트

- Apple Watch 현장 설치·수신·동기화 확인
- Paid Apps Agreement 활성화·`com.taption.plan.pro` 생성·sandbox 구매/복원 확인

## 2026-09-02 DEV901A001 실기기 이전 기록 정합성 검증

- 대상: iPhone 14 Pro (`C44AF739-127D-572D-AD83-417C7E879045`), iOS 26.6.1
- 최신 서명 Debug 설치·readback: `Taption Plan com.taption.plan 1.0 125`, launch 성공
- 실제 기기 XCTest: 라우트·재생·시간축·날씨 관련 203건 통과, 실패 0건 (`/private/tmp/DEV901A001-device-tests-v2.xcresult`)
- 최신 전체 시뮬레이터 XCTest: 894건 통과, 실패·건너뜀 0건 (`/private/tmp/DEV901A001-full-tests-v2.xcresult`)
- 정본 대조: 2026-08-31 actuals 0건, travel 153건(확정 2건), places 300건, 관측 weather 0건; 계산된 약 1,252분 미확인 구간은 저장 데이터와 일치
- 2026-09-01 weather 1,936건은 동시 위치·예보 context 중복이었고, MapHome 표시 투영에서 같은 분 대표값 1건으로 축약하는 회귀 테스트 통과
- 날짜 전환 stale 데이터·공백 재생 fallback·연속 GPS 이동의 예상 점선 회귀 수정은 실제 기기 테스트 대상에 포함되어 통과
## 2026-09-02 DEV901A001 iPhone Mirroring 화면 검증

- 대상: iPhone 14 Pro (`C44AF739-127D-572D-AD83-417C7E879045`), 설치 `Taption Plan 1.0 (125)`
- Mirroring에서 Plan 화면을 열고 2026-09-02 → 2026-09-01 날짜 이동, 2026-09-01 지도·weather rail 렌더링, 시간축 23:59 → 11:54 이동을 확인했다.
- 2026-09-01 재생에서 버튼이 일시정지 상태로 전환되고 선택 시간이 11:54 → 12:34 → 15:30으로 진행되며 지도 경로·졸라맨 표시가 stale 경로로 점프하지 않는 것을 확인했다. 정지 후 2026-09-02로 복귀했다.
- 2026-09-02 재생에서 선택 시간이 01:20 → 01:49로 진행되고 재생 중 경로가 비정상적으로 이전 날짜/마지막 leg를 재사용하지 않는 것을 확인했다.
- 지도 단일 손가락 이동, 확대/축소 컨트롤, 현재 위치 복원을 실제 터치로 확인했다. Mirroring 자동 입력 API에는 다중 손가락 pinch 입력이 없어 pinch 자체의 물리 latency는 직접 측정하지 못했으며, 해당 MagnificationGesture 입력 예산은 소스 회귀 테스트로 검증했다.

## 2026-09-02 REL902A001 TestFlight build-up

- 배포 소스는 `6b302ea2f9bca3f818c829514af1ee147b83be47`이며 `main`·`origin/main`이 일치한 상태에서 build number를 126으로 올렸다.
- Debug generic iOS build 성공: `1.0 (126)`, `/private/tmp/REL902A001-debug-derived/Build/Products/Debug-iphoneos/TaptionPlan.app`.
- Release archive/export 성공: `/private/tmp/REL902A001-release/TaptionPlan-1.0-126.xcarchive`, `/private/tmp/REL902A001-release/Export/TaptionPlan.ipa`. IPA SHA-256은 `5db4f2dbb11f7fa3ac64aca515dc6fd3474c35ecc6e19ddcff1373f56664ed25`이다.
- IPA의 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (126)`, Apple Distribution 서명, `beta-reports-active=true`, `get-task-allow=false`, deep/strict codesign을 확인했다. `altool --validate-app`도 오류 없이 통과했다.
- TestFlight 업로드 성공: Delivery UUID `8e66a688-a922-4f76-b761-4da7b3faadb1`; App Store Connect API readback에서 build `126`이 `VALID`, `APP_STORE_ELIGIBLE`, `expired=false`로 확인됐다.
- `TP Taption Plan 내부 테스트`(internal group, ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 build `126` 연결 성공. 그룹 빌드 API에서 `87개`와 build `126` `VALID`, 내부 테스터 API에서 `1명`(`axony99@gmail.com`)을 readback했다.
- App Store Connect 그룹 빌드 화면·테스터 화면은 연결된 Chrome과 in-app Browser가 로그인 화면으로 열려 계정 자격 증명을 입력하지 않았으므로 미완료 게이트로 남긴다.

## 2026-09-02 CLN902A001 저장공간 정리

- 정리 전 readback: 데이터 볼륨 여유 39GiB, `/private/tmp` 약 77G, CoreSimulator 약 26G.
- 종료 상태였던 iOS 26.5 Simulator 5대의 device data를 삭제했다: `37ED8B8E-1EA0-43DF-BC49-D43B91CC3A0A`, `A1BCAC6A-AA32-4D3F-90A9-FF3CBAE39CC1`, `3D26B7FD-55B0-4404-BA2F-44FE1C6FBB8D`, `4E0207AD-E023-4D87-8089-00F476421D04`, `75BE290F-DC49-4540-9901-127E6D0074A6`. iOS/watchOS 26.5 runtime은 보존했다.
- 문서에 남은 증적·REL902A001 release archive·활성 카메라 로그를 제외하고, 2026-09-01 이전 소유 가능한 `/private/tmp` 임시 산출물 2,387개 약 27.92G를 정리했다. root 소유 `FTABHarvest` 1개는 권한 보호로 보존했다.
- 정리 후 readback: `/private/tmp` 50G, 데이터 볼륨 여유 61GiB, CoreSimulator 2.1G. `XCTestDevices`·Xcode `DerivedData`는 0B, Xcode `Archives` 1.4G는 보존했다.
- 정리 직후 다른 작업이 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`를 부팅하고 `WBS33GOAL1` XCTest를 실행 중인 것을 확인해 해당 작업과 현재 산출물을 보존했다. CoreDevice가 사용 중인 `/private/tmp/CAM30LIBR1-stage4-REZrnD`와 `/private/tmp/CAM29LIVE3-camera-r4.jsonl`도 보존했다.
- 사용자 휴지통 readback은 0개이며, 현재 Taption Plan 소스·Git 상태와 build 126 release 증적은 삭제하지 않았다.

## 2026-09-02 REL902A002 TestFlight build-up

- 배포 소스 커밋 `311b5832cc9819e91f16c79af2970eb7a6dbc51b`을 `main`에 커밋·푸시했고, archive 시점 `main`·`origin/main`·원격 main 일치 및 tracked/untracked clean을 확인했다.
- Release archive/export 성공: `/private/tmp/REL902A002-release-v2/TaptionPlan-1.0-127.xcarchive`, `/private/tmp/REL902A002-release-v2/Export/TaptionPlan.ipa`; IPA SHA-256 `05f179337b4bdaa5c7dcd887adc1f5246ccd27de00d0d394210829f2c99c8aa0`.
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (127)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign·`altool --validate-app` 통과.
- TestFlight 업로드 성공: Delivery UUID `3297b1a2-fde1-40b3-b219-b99f13cf4c1e`; App Store Connect API에서 build 127 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false` 처리 완료를 확인했다.
- `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 build 127 연결 성공. 그룹 빌드 API에서 전체 88개와 build 127, 테스터 API에서 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- App Store Connect 그룹 빌드·테스터 실제 화면은 Chrome과 in-app Browser가 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 UI readback은 미완료다. TestFlight build 127 실기기 설치·launch·실제 터치도 별도 게이트다.

## 2026-09-03 TF26PUSH01 build-up·기기 설치

- 배포 소스 `84448b8aa8fc7b9de35b2903561a90095c2bee62`를 `main`에 커밋·푸시하고 build number를 `128`로 올렸다.
- package 테스트: Core 40/40, Activity 12/12, Route 17/17, Engine 1/1 통과.
- Release archive/export 성공: `/private/tmp/TF26PUSH01-release-r2/TaptionPlan-1.0-128.xcarchive`, `/private/tmp/TF26PUSH01-release-r2/Export/TaptionPlan.ipa`; IPA SHA-256 `b6532fc4be01c52a03fe1ef85f60b3bdb5156f77901cdd7483812834db9154e6`.
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (128)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign·`altool --validate-app` 통과.
- TestFlight 업로드 성공: Delivery UUID `3ce79d87-b2cd-429e-b988-816d0b9af84a`; App Store Connect API readback `VALID`, `APP_STORE_ELIGIBLE`, `expired=false`.
- `TP Taption Plan 내부 테스트` 연결 성공. 그룹 빌드 API readback은 전체 89개·build 128 `VALID`, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)이다.
- iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`) TestFlight 업데이트 후 `com.taption.plan` `1.0 (128)` 설치와 launch PID `26948`를 readback했다.
- iPad Pro(`4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`)는 현재 `Taption Plan 1.0 (125)`이다. CoreDevice로 beta IPA를 직접 설치할 수 없어(`0xe800801f`, beta profile entitlement 오류) TestFlight 앱을 통한 build 128 다운로드·설치·launch는 남은 게이트다.
- ASC 그룹·테스터 실제 화면은 로그인 필요로 미완료다. 관련 로그: `/private/tmp/TF26PUSH01-asc-readback.json`, `/private/tmp/TF26PUSH01-iphone-launch.json`, `/private/tmp/TF26PUSH01-ipad-before-apps.log`.

## 2026-09-03 SLP903TF02 수면 연결 복구·build 129

- iCloud 백업은 정상이고 Watch snapshot의 `health_enabled=false` 때문에 HealthKit 수면 refresh가 실행되지 않은 원인을 확인했다.
- 오늘 수면이 없고 건강 연동이 꺼진 경우만 `수면 연결` 안내를 표시하는 회귀 테스트를 포함해 전체 XCTest 901/901, 실패·스킵 0을 통과했다: `/private/tmp/SLP903TF02-full.xcresult`.
- generic iOS Debug build와 Release archive/export를 통과했다. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (129)`, Production iCloud/TestFlight entitlement와 deep/strict codesign, `altool --validate-app`이 정상이다.
- IPA SHA-256은 `3acc55045b44c3bbc94e6172edf43f372ab9efba467b347e65b8aec2d546c723`, Delivery UUID는 `411a22f3-430a-48fb-bde7-03269ca710e6`이다.
- App Store Connect API에서 build 129 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 연결, 그룹 build 90개 중 build 129, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- HealthKit 권한 승인과 오늘 수면 실제 생성은 사용자 탭이 필요한 별도 실기기 게이트다. iPad에는 TestFlight `4.3.0 (659.1)`이 설치돼 있으며 앱 build 129 다운로드·설치·launch가 남아 있다.

## 2026-09-03 SID903A001 날짜 전환 사이드바 회귀

- 날짜 전환 초기화에서 전체 `미확인` 대입을 제거하고 선택 날짜의 actual·travel 대분류를 즉시 투영한다.
- `TimeScaleTests.testMapHomeSidebarDateChangeProjectsTheSelectedDaysMajorCategories` 통과, 실패 0: `/private/tmp/SID903A001-focused-r2.xcresult`.
- 테스트 실행 과정의 Debug 앱·Widget·Watch target 빌드가 성공했다. 실제 기기 날짜 전환 화면 확인은 별도 게이트다.

## 2026-09-03 TF903B013X TestFlight build 130

- 전체 XCTest 902/902, 실패·스킵 0: `/private/tmp/TF903B013X-full.xcresult`.
- Release archive/export 성공. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (130)`, Production iCloud/TestFlight entitlement와 deep/strict codesign, `altool --validate-app` 통과.
- IPA SHA-256 `0904b72f68a00f32bd7cd29b48c027acfb4764c684d3696265b1fb1035218fa8`, Delivery UUID `064f2803-95d1-458b-96bc-819b087c13c9`.
- App Store Connect API에서 build 130 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 연결, 그룹 build 91개 중 build 130, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 130 실기기 설치·launch와 날짜 변경 실제 화면 확인은 별도 게이트다.

## 2026-09-03 REL903TF01 TestFlight build 131

- `MapHomeStickmanTests.testOnlyMovementStickmanActionsAnimate` 통과, 실패 0. 테스트 실행 과정의 Debug 앱·Widget·Watch target 빌드도 성공했다.
- Release archive/export 성공. 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (131)`, deep/strict codesign과 `altool --validate-app` 통과.
- IPA SHA-256 `4435667dba069fda3706217b5c6af8947cef75eb72689525bc2fd75dd603f6f8`, Delivery/build UUID `805169b0-e3d9-41b2-883d-475504a3884d`.
- App Store Connect API에서 build 131 `VALID`·`expired=false`, 내부 그룹 연결, 그룹 build 92개 중 build 131, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 131 실기기 설치·launch와 실제 Watch 설정·비이동 정지 화면 확인은 별도 게이트다.

## 2026-09-04 LOG904TF01 TestFlight build 132

- 지하철 잠금 교체·권한 재안내·진단 요약 집중 XCTest 4/4 통과, Release archive/export와 `altool --validate-app` 통과.
- 네 번들 `1.0 (132)`, IPA SHA-256 `afc0a852750c0b67e017453a5b9c3aea05cf6b41bb89be211185496ac4de0b5b`, Delivery/build UUID `5d01450c-2c10-4b8f-bcff-8852258fe2f1`.
- App Store Connect API에서 build 132 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`, 내부 그룹 연결, 그룹 build 93개 중 build 132, 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 132 설치·launch 및 지하철·예상경로·수면 로그 확인은 대표님 테스트 후 진행할 별도 실기기 게이트다.

## 2026-09-04 TFB904A133 TestFlight build 133

- 실행 성능 수정 커밋 `8d041e9284d8393cbbf1157cf2b795c1cb6b51cf`, 배포 소스 `3930b808c86f20b003e474c56846252156303b41` 기준 관련 XCTest 4/4와 generic iOS Simulator Debug build가 통과했다: `/private/tmp/TFB904A133-focused.xcresult`.
- Release archive/export와 `altool --validate-app` 통과. 네 번들 모두 `1.0 (133)`, Apple Distribution 서명, TestFlight entitlement 정상이다. IPA SHA-256은 `422bcb43a8822b7eac2ff7935471acecddd5a46c2ade6a506ccf6cebdda92f4a`다.
- Delivery/build UUID `bc2b0f81-83f2-4001-80f2-19707a1b1fcc`는 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. Internal 그룹 연결 후 API에서 그룹 build 94개 중 build 133과 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome 그룹 빌드 화면에서 build `1.0 (133) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 그룹 `94개의 빌드`를 확인했다. 현재 설치 표시는 `1.0 (132)`이며 build 133 설치·launch·실제 화면·발열은 미확인이다.

## 2026-09-04 REL904A001 TestFlight build 134

- 위치·수면·경로·지하철 수정 후 `TaptionActivityEngine` 12/12, iOS 집중 XCTest 3/3, Debug build를 통과했다.
- `main` 커밋·푸시: `f99d72b93919e8646a6fc7d9908330e524eb6034`; Release archive/export 성공, 네 번들 `1.0 (134)`, IPA SHA-256 `225ba74b3de11b05e1c4a530d20a21b495b34ca0b22f8af503184b9dabf45851`.
- `altool --validate-app` 및 TestFlight 업로드 성공. Delivery UUID `a3581625-8668-4d3a-85c1-240078bc054e`; App Store Connect API에서 build 134 `VALID`·`expired=false` 확인.
- `TP Taption Plan 내부 테스트` 연결 성공. 그룹 빌드 API에서 build 134와 내부 테스터 1명을 readback했으며, 테스터 설치·실행은 아직 확인하지 않았다.
