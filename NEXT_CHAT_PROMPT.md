# Taption Plan 다음 채팅 인계 프롬프트

## 2026-08-30 BTCH830Q16 · temp.md 전체 실행 최신 상태

- `SENS830Q14`를 구현했다. Watch+iPhone가 겹치는 시각에는 Watch 행동을 우선한 결합 evidence를 사용하고, Watch가 없으면 iPhone evidence만 사용한다. 이동수단 상세는 Plan 이동 알고리즘 결과가 있을 때만 projection한다.
- `ActivityClassificationProjection` version 1에 기존 9개 major ID와 manual/locked override 보존 경계를 추가했다. raw iPhone·Apple Watch reading과 provenance는 변경하지 않았다.
- `RoutePlaybackProjection`에 누적거리 재생, 1% look-ahead 8방향, 24프레임 결정 index, route/marker 동일 좌표 projection을 추가했다.
- 자동 검증: ActivityEngine 6건, RouteEngine 14건, PlanCore 30건, 잠금 분류 보강 후 `TaptionActivityEngineAdapterTests` 10건, 관련 지도·재생·사이드바·졸라맨·분류 회귀 688건 통과. 최종 회귀 결과 bundle: `/private/tmp/taption-plan-btch830q16-regression-final.xcresult`. 최종 소스 Debug 빌드는 iOS `/private/tmp/taption-plan-btch830q16-ios-build2/Build/Products/Debug-iphoneos/TaptionPlan.app`, Watch `/private/tmp/taption-plan-btch830q16-watch-build2/Build/Products/Debug-watchos/TaptionPlanWatch.app`, Widget `/private/tmp/taption-plan-btch830q16-watch-build2/Build/Products/Debug-watchos/TaptionPlanWatchWidget.appex`에서 `1.0 (115)`를 readback했다.
- 실기기 iPhone/Apple Watch provenance·화면, 목요일 경로 재생·졸라맨·지도 비율·좌우 핸들·Dynamic Island는 미완료로 유지한다. 추정으로 완료 처리하지 않는다.

Taption Plan 작업을 이어간다. 작업 디렉터리는 `/Users/u_mo_c/Documents/taption plan`이다.

## 2026-08-30 RELD830Q10 · 전달 게이트 최신 기록

- Plan `main` 커밋·원격 푸시 후 clean을 확인하고 WBS 저장소의 dirty 변경은 보존했다.
- Release archive/export가 `/private/tmp/taption-plan-reld830q10-auto.xcarchive` 및 `/private/tmp/taption-plan-reld830q10-export/TaptionPlan.ipa`에서 성공했다.
- TestFlight upload Delivery UUID: `f29953e9-7f46-40da-a5a3-e62b1c543d4f`
- App Store Connect build `1.0 (115)`는 `VALID / APP_STORE_ELIGIBLE`이며 `TP Taption Plan 내부 테스트` 그룹에 연결되고 그룹 목록에 노출됐다.
- IPA는 `com.taption.plan`, Apple Distribution, beta entitlement, `1.0 (115)`로 readback됐다.
- iPhone 14 Pro에 동일 소스의 개발 서명 Debug 앱 `/private/tmp/taption-plan-reld830q10-device/Build/Products/Debug-iphoneos/TaptionPlan.app`을 설치·실행했다. `com.taption.plan / 1.0 / 115` 앱 목록 readback 성공. TestFlight 그룹 노출과 iPhone 직접 설치·실제 화면·터치는 독립 게이트로 기록한다.

## 2026-08-30 WBSI830Q08 · DATA830Q09 최신 인계

이번 실행의 목표는 Taption WBS의 데이터 관리·불러오기 경계까지 Plan에 적용하는 것이다.

- WBS 저장소 `/Users/u_mo_c/Documents/Taption WBS`의 현재 dirty 작업본은 읽기 전용 기준으로만 사용한다. WBS 소스와 WBS `temp.md`는 수정하지 않는다.
- Plan의 SQLite 정본, `RawDeviceDataDayArchive` 원본 envelope, `SensorReadingArchive`를 유지하고, iPhone·Apple Watch raw record와 provenance를 덮어쓰지 않는다.
- WBS의 `정본 로드 → 정상화된 일 단위 파생본 → 화면 캐시` 경계를 Plan의 `PlanDayDataSnapshot`으로 적용한다. snapshot은 source revision·updatedAt을 고정하고 actual/place/travel/reading을 해당 날짜로만 투영한다.
- 중복 센서 ID는 결정적으로 하나로 정리하고 시간순으로 읽는다. 날짜 경계와 15분 초과 GPS 공백은 재생 projection에서 분리한다. 빈 로드는 기존 당일 경로를 지우지 않는다.
- 지도는 Apple `mutedStandard`·flat·muted·light·POI 제외·교통량 숨김·paper `#FCF9F4`로 실행한다. 기존 MapDisplayStyle raw value와 MapLibre 코드는 호환성을 위해 읽되 기본 실행 경로에 노출하지 않는다.
- 지도 현재 위치·나침반·재생·스크럽은 중심/방위만 갱신하고 zoom/span/distance/pitch를 보존한다. 실제 경로·이동·체류 순서와 누적거리 보간, 1% look-ahead 8방향, 목적지 30m 체류를 유지한다.
- 졸라맨은 18개 Codable action, WBS 2등신 비율·갈색 `#916446` 선·회색 `#B7B1A8` 머리·24프레임/12fps를 사용하며 heading은 계산만 하고 몸·얼굴·머리는 회전하지 않는다.
- 좌우 핸들은 같은 동작을 사용하고 오른쪽 터치 높이는 88pt의 1.5배인 132pt다. 입력은 240Hz까지 받되 화면 반영은 최대 60Hz로 합치고 종료값은 즉시 반영한다.

현재 자동 검증 증거:

- 전체 `TaptionPlanTests`: 815건 통과. 결과: `/Users/u_mo_c/Library/Developer/Xcode/DerivedData/TaptionPlan-gvqtjbpzkfvutrdlxdzhdyhsyane/Logs/Test/Test-TaptionPlan-2026.08.30_04-43-27-+0900.xcresult`
- `swift test --package-path Packages/TaptionRouteEngine`: 11건 통과
- `swift test --package-path Packages/TaptionActivityEngine`: 4건 통과
- `swift test --package-path Packages/TaptionPlanCore`: 30건 통과
- `git diff --check`: 통과
- iOS Simulator `MAP30CNT01 Test`에서 자동 테스트를 실행했다. 실기기 화면·터치·Dynamic Island·Watch 지연 동기화는 설치 후 별도 게이트로 확인해야 한다.

다음 실행 순서:

1. 이 문서와 `AGENTS.md`, `DEVELOPMENT.md`, `temp.md`, `test.md`를 읽고 Plan/WBS dirty 상태와 SHA를 다시 확인한다.
2. 최신 Debug `1.0 (115)`를 iPhone 14 Pro에 설치하고 `com.taption.plan` 버전·실행을 readback한다.
3. PIN 해제 후 목요일 경로 재생, 실제/예상 경로 색상, 졸라맨 경로 추종·비회전, 현재 위치·나침반·재생 중 지도 비율 고정, 좌우 핸들 1.5배 터치를 실제 화면에서 확인한다.
4. Apple Watch 원본 데이터·provenance 불변 및 동기화, Widget/Live Activity/Dynamic Island를 별도 readback한다.
5. 증거를 `test.md`에 기록하고, 물리 게이트가 모두 닫힌 항목만 `temp.md`에서 삭제한다.
6. 승인된 Plan 파일만 `main`에 `fix: port WBS map playback and speed up sidebar`로 커밋·푸시하고 로컬/원격 SHA와 clean worktree를 확인한다.

중단 조건:

- WBS dirty 파일의 소유권이 불명확하거나 WBS를 수정해야 하면 즉시 중단하고 보고한다.
- 원본 iPhone·Watch record 또는 provenance를 수정해야 하는 설계가 나오면 파생 projection으로 전환하고 중단한다.
- 실기기 잠금·권한·서명·계정 게이트가 막히면 추정으로 완료하지 말고 명령·오류·미완료 범위를 `test.md`에 남긴다.

먼저 `AGENTS.md`를 끝까지 읽고 현재 상태를 직접 확인한다. 아래 기록의 SHA·기기·권한·TestFlight 상태는 시점 정보이므로 최신 사실로 가정하지 않는다.

```sh
cd "/Users/u_mo_c/Documents/taption plan"
git status --short --branch
git log -5 --oneline --decorate
git rev-parse HEAD origin/main
git diff --check
sed -n '1,520p' DEVELOPMENT.md
test -f temp.md && sed -n '1,240p' temp.md || true
xcrun devicectl list devices
xcrun devicectl device info apps --device C44AF739-127D-572D-AD83-417C7E879045
```

## 2026-08-29 DOC9M4K7P2 최신 인계 상태

- STK9V6Q2M4 구현과 개발문서 변경은 기능·개발문서 커밋 `eb66bf3a166f0ff67f834f1c5c049a1bcd38b2b9`로 `origin/main`에 푸시했다. 이 인계 파일을 추가한 커밋까지 포함한 최신 SHA는 아래 시작 명령으로 다시 확인한다.
- 지도 Canvas 졸라맨은 18개 행동의 관절·시점·소품을 재설계했다. 활동은 정면→왼쪽 옆→오른쪽 옆, 걷기·달리기·일반 이동·버스·선박·자전거는 옆면, 업무는 오른쪽 사선 뒤, 학교·식사·운동은 왼쪽 사선 앞, 취미·미확인은 정면, 수면은 옆면, 차량은 정면이다.
- 업무 모니터 텍스트·키보드 입력, 학교 책장 넘김, 취미 마이크·노래 입 모양, 수면 침대·베개·이불·호흡·Z, 차량 운전대, 선박 난간·물결, 비행기 큰 창·탑승자, 2량 지하철 큰 창·정면 승객·손잡이, 버스 손잡이, 자전거 페달을 포함한다.
- `자가용` 데이터는 지도 렌더링에서 `.car`로 통합했으며 Live Activity의 별도 `privateVehicle` 계약은 유지한다. 예상경로·재생 위치 투영과 12프레임/Reduce Motion 계약도 유지한다.
- 최신 소스 기준 generic iOS Debug build, iOS Simulator `build-for-testing`, `git diff --check`가 통과했다. 사용 가능한 iOS Simulator 기기는 없고, 최종 렌더 세부 패치 후 iPhone 14 Pro 재실행은 잠금 상태로 `deviceprep`에서 차단됐다.
- iPhone 14 Pro `MapHomeStickmanTests` 20/20과 앱 실행은 최종 렌더 세부 패치 전 통과 기록이다. 최종 소스의 실제 화면·터치·18개 동작 시각 확인은 아직 닫지 않는다. 이번 변경에는 archive/upload/TestFlight 실행 기록이 없다.
- 다음 채팅은 먼저 기기 잠금을 해제한 뒤 최신 Debug 앱을 설치·실행하고, 지도 현재/과거 위치·예상경로·재생에서 18개 동작과 경로 이동을 실제 터치·화면으로 확인한다. 그 뒤 로그와 관련 XCTest를 다시 기록한다.

### 새 채팅에서 지킬 범위

- `AGENTS.md`와 `DEVELOPMENT.md`를 먼저 읽고, `temp.md`에 새 요청을 영문·숫자 10자리 ID로 기록한다. 대표님이 `ㄱㄱ` 또는 `전체 진행`이라고 하기 전에는 구현하지 않는다.
- 현재 요청 범위 밖의 UI/UX·지도 제공자·서명·배포 설정은 임의로 바꾸지 않는다. 실기기 설치·실행·화면 터치·HealthKit/Watch·archive/upload·TestFlight 내부 그룹 readback을 서로 다른 게이트로 기록한다.
- 워크트리가 dirty이면 기존 변경을 먼저 보존하고, 새 파일·DerivedData·테스트 결과를 정리할 때는 저장소 증거와 다른 프로젝트 공유 산출물을 삭제하지 않는다.

## 2026-08-28 인계 상태

- 구현 커밋 `b707adf`와 최신 인계 문서가 `main`에 push되었고 현재 워크트리는 clean이다. 다음 채팅에서 위 명령으로 최신 HEAD와 원격을 다시 readback한다.
- 앱은 `com.taption.plan`, 최신 TestFlight 기준 버전 `1.0 (109)`이며 `TP Taption Plan 내부 테스트`에서 `테스트 중`이다.
- 이번 변경에서 generic iOS Debug build와 generic iOS `build-for-testing`, Release archive/export/upload가 성공했다. 서명 Debug 앱 `1.0 (109)`을 iPhone 14 Pro와 Apple Watch SE에, `1.0 (108)`을 iPad Pro에 설치·launch했다. `MapHomeStickmanTests` 16건도 통과했다.
- 최신 iPhone 전체 XCTest는 783건 중 781건 통과했다. 실패 2건은 저장소에 없는 `TaptionPlan/Localizable.xcstrings`와 `.cat-visual-check/cat_sheet_x4.png` fixture다.
- iPad Pro 12.9-inch 전체 XCTest도 783건 중 781건 통과했으며, 동일한 2개 fixture 누락으로 실패했다.
- 누락으로 기록된 두 fixture 테스트는 현재 iPhone·iPad targeted 재실행에서 모두 통과했으며, 전체 재실행 재시도는 로컬 `4FWG8XXYM` iOS Development 인증서·프로파일 부재로 빌드 단계에서 중단됐다.
- 현재 사용 가능한 iOS Simulator가 없고, iPhone 미러링도 기기가 사용 중이라 잠금 전 연결 시간이 초과되어 지도/HealthKit 실제 touch readback은 `test.md`에 미검증 게이트로 남겼다. iPad는 서명 Debug `1.0 (108)` 설치·launch까지 readback했지만 화면·터치는 별도 미검증이다.
- iPhone 14 Pro(CoreDevice `C44AF739-127D-572D-AD83-417C7E879045`, UDID `00008120-00092C3E14F0201E`, iOS 26.6.1)의 현재 설치 앱은 `com.taption.plan`, 버전 `1.0 (109)`이며 이번 서명 Debug 앱으로 갱신·launch했다.
- Apple Watch SE(CoreDevice `9229A9F2-B4F1-5A44-ACFA-0E5B00F3B3AF`)의 현재 설치 앱은 `com.taption.plan.watchkitapp`, 버전 `1.0 (109)`이며 이번 서명 Debug 앱으로 갱신·launch했다.
- build 108은 App Store Connect `제출 준비 완료` 처리 후 `TP Taption Plan 내부 테스트`에 연결했고, 그룹 빌드 화면에서 `1.0 (108) · 테스트 중 · iOS`를 readback했다.
- build 109는 App Store Connect `제출 준비 완료` 처리 후 `TP Taption Plan 내부 테스트`에 연결했고, 그룹 빌드 화면에서 `1.0 (109) · 테스트 중 · iOS`를 readback했다.
- 현재 iPad에는 서명 Debug `1.0 (108)`이 설치·launch되어 있다. TestFlight Distribution IPA 직접 설치는 Beta entitlement 제약으로 별도 미완료다.
- `temp.md`는 현재 비어 있으며, iPhone 미러링 잠금·실제 화면/터치, HealthKit 권한·원본, Watch 지연 동기화, Dynamic Island, IAP 외부 게이트가 `test.md`에 남아 있다.
- DerivedData·xcresult·저장소의 재생성 캐시는 작업 종료 때 삭제했다.

## 반영된 구현

### HealthKit 전체 이력·원본

- `HealthKitTypeCatalog`가 공개 HealthKit 타입군을 카탈로그화하고 타입별 최소 OS·단위·민감도·조회 방식을 관리한다.
- 타입별 anchor와 불변 원본을 파일 보호된 로컬 SQLite에 저장하고, UUID·기간·값·단위·source revision·device·사용자 입력·시간대·삭제 이력을 보존한다.
- 전체 이력은 월 단위 체크포인트로 재개 가능하게 가져오며, observer와 anchored query로 추가·삭제분을 증분 동기화한다.
- HealthKit 원본은 iCloud·CloudKit·위젯 payload·일반 센서 raw export에서 제외한다.
- 운동·수면·명시적 복약/건강 이벤트와 개인 기준선을 충족한 연속 생체값은 비의료 행동 후보로 projection하고 근거 provenance를 유지한다.
- 건강관리 대분류가 시간 레일·색상·위젯 분류에 추가됐다.
- 실기기에서 표준 권한 요청에 vision prescription·blood pressure correlation·food correlation을 함께 넘기면 `NSInvalidArgumentException`으로 종료되는 문제를 수정했다. correlation은 구성 quantity 타입 권한을 사용하고 vision prescription은 per-object authorization 경로를 사용한다.

### 지도·경로·센서

- MapLibre Native와 OpenFreeMap 벡터 소스를 사용한 `벡터 야간`, `벡터 밝은 지도`, `벡터 고대비`, `벡터 파스텔` 스타일이 지도 스타일 선택에 추가됐다.
- 벡터 지도는 라벨·상점 POI를 제외하고 건물·도로·물·토지, 노란 경로, 삼각형 플레이어, 기존 위치·장소·대중교통 annotation overlay를 표시한다.
- 실제/예상/지하철 경로와 플레이헤드 위치·방향·추적/팬/줌 상태를 MapLibre에서도 유지한다.
- raw 위치의 자정 경계·선택일 구간 조회와 지하철 GPS 공백의 예상 경로 projection을 보강했다. 확정 선로는 정본으로 우선하고 추정 경로는 점선으로 구분한다.
- `BCH828STK1`/`STK828M5Q2`에서 하단 팝업 스티커 메뉴를 복구하고, 지도 메모를 `전부 보기`/`해당되는 것만 보기`로 필터링한다. 스티커는 지도·일정에 각각 추가할 수 있으며, 스티커 모드에서 지도 스티커와 지도 메모를 탭해 위치·시간·내용을 수정하거나 삭제할 수 있다. 저장 스냅샷·Cloud tombstone·구버전 메모 decode를 보강했다.
- 센서 day-store 원본과 월별 raw archive, iCloud에서 제외되는 로컬 원본 정책을 유지한다.
- 3분 이상 체류한 등록 위치·MapKit 주변 5종 교통 후보에 물음표와 탑승/삭제 메뉴를 제공하고, 삭제 결정은 장소 종류·좌표·체류 구간으로 근방 재생성 후보까지 억제한다.
- `MAP28FIXQ1`에서 MapKit POI 이름·식별자·좌표·도착 분이 바뀌어도 삭제 후보를 억제하고, 100m 이내 인접 후보를 함께 숨기도록 보강했다. MapLibre viewport는 최신값 coalescing, transient overlay, 후보 presentation cache로 부모 전체 재평가를 줄이며 지도 계산은 최대 60Hz, 부모 readback은 15Hz로 제한한다.

### 졸라맨 자연스러운 동작

- 18개 행동의 관절을 IK로 연결하고, 보행 접지·스윙·달리기 체공·골반 이동·팔/다리 반대 위상·자전거 페달 위상을 적용했다.
- 기존 진분홍 단색, 둥근 선, 64×56 좌표계, 소품과 렌더러 인터페이스는 유지한다.

### 졸라맨·사이드바·위젯

- 지도 졸라맨은 모든 annotation보다 앞에 표시하고 사이드바 핸들에서는 제거했다.
- 대분류와 이동 상세별 졸라맨/소품 애니메이션, 걷기 배경 이동, Dynamic Island/Live Activity 표현과 재현 기준은 `STICKMAN_ANIMATION_GUIDE.md`에 정리돼 있다.
- 날씨는 사이드바에 붙여 표시하고, 시간 핸들 및 대분류 색상·건강관리 색상과 위젯 표현을 통합했다.
- 고빈도 사이드바 입력은 최대 60Hz 렌더 예산으로 합치고 제스처 종료 최종값은 즉시 반영한다.

## 아직 실기기에서 확인할 항목

1. `HLTH28P7Q4`: iPhone에서 새 HealthKit 권한 시트와 vision prescription per-object 선택을 직접 완료한 뒤 전체 이력 진행률·원본 건수·source/device provenance를 읽는다.
2. 페어링 Apple Watch 데이터의 지연 도착, 백그라운드 observer 전달, 재실행 후 anchor 증분 동기화를 실기기에서 확인한다. Watch가 offline이면 완료로 처리하지 않는다.
3. `SLEEP827B2`: 2026-08-27 07:15 전후 HealthKit 수면 원본 종료 시각과 걸음/화면 사용 근거를 앱 진단 경로에서 대조한다. 확인되지 않은 휴대폰 터치 시각을 수면 원본으로 만들지 않는다.
4. `NXT27AUG01`: Dynamic Island compact/expanded, 재생·사이드바 실제 터치, 졸라맨 최전면, MapLibre 4개 스타일, 지하철 확정/예상 경로를 iPhone 화면에서 수동 확인한다.
5. `IAP73PAID1`은 Paid Apps Agreement·세금/은행·상품 연결·Sandbox 구매/복원 전까지 완료 처리하지 않는다.
6. `STK28NAT9Q`: iPhone에서 18개 졸라맨 동작의 렌더링·전환을 실제 화면으로 확인한다.

새 요청은 영문·숫자 10자리 ID로 `temp.md`에 먼저 기록하고, 대표님의 `ㄱㄱ` 또는 `전체 진행` 승인 뒤 실행한다. 완료된 항목만 큐에서 제거한다.
