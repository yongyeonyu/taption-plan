# Taption Plan 개발 문서

## 2026-09-05 REL905H007 · build 135 정확도·성능 보강 릴리스

- 자동 기록·경로 생성·행동 분류·센서/Watch 분기·지도 상호작용을 다방면 검토해 확인된 결함을 최소 수정했다. 불완전 일자 캐시, stale projection/migration, 과도한 날짜 조회, 경로 opacity·MapKit overlay 교체, 현재 위치 중복 표시, Watch 유료 잠금 우회를 바로잡았다.
- 전체 앱 테스트는 1,027건 중 1,026건 통과·실패 0·iOS 26.5 StoreKit 시스템 결함 1건만 skip했다. 집중 회귀 6/6, 성능 회귀 4/4, 30일 로드 cold/warm p95 `33.154708ms`/`0.007334ms`, generic iOS·watchOS Debug와 정적 분석을 통과했다.
- 배포 소스 `1ca699e5f0da06c18dd453b31c688c5b38405a31`을 `main`에 푸시하고 앱·iOS Widget·Watch 앱·Watch Widget을 `1.0 (135)`로 archive/export했다. IPA SHA-256은 `f2f5ef3b106fb37c480b1e365888fe66844c4c111c0d06b990b9c7bc110807e3`이다.
- 배포 IPA는 Apple Distribution 서명, `beta-reports-active=true`, iCloud `Production`, `get-task-allow=false`, privacy manifest와 deep/strict codesign을 확인했다.
- App Store Connect 업로드 Delivery/build UUID는 `365a5ef7-dfda-447f-8b4c-3c807f1ef37e`이며 `VALID`·미만료·`APP_STORE_ELIGIBLE`이다. `TP Taption Plan 내부 테스트`에 API로 추가한 뒤 build 135 포함·그룹 빌드 96개·내부 테스터 1명을 readback했다.
- TestFlight 클라이언트의 build 135 실기기 설치·실행, 장시간 발열/배터리, 두 손가락 pinch, iPhone/Watch 실제 센서·수면·지하철 수신은 별도 물리 게이트로 남긴다.

## 2026-08-30 DOCS83047A · 문서 범위 정리

- 사용자 선택 3에 따라 현재 구현 범위와 직접 연결되지 않은 `ACTION_ITEMS.md`와 구현 전 아이디어 문서 `GAME_plan.md`를 삭제했다.
- 현재 유지 문서는 Taption Plan의 구현·기획·검증·인계에 직접 쓰이는 자료로 한정한다. 원본 센서·Watch 데이터와 WBS 저장소는 수정하지 않았다.

## 2026-08-30 MDCL83048A · 전체 Markdown 범위 점검

- 저장소의 `.md` 파일 전체를 확인한 결과, 남은 `AGENTS.md`, `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `README.md`, `SENSOR_FUSION_SOURCES.md`, `STICKMAN_ANIMATION_GUIDE.md`, `design-qa.md`, `plan.md`, `temp.md`, `test.md`는 모두 Taption Plan의 개발 규칙·구현·기획·검증·인계에 직접 연결된다.
- 프로젝트와 무관한 `.md` 파일은 추가로 확인되지 않아 삭제하지 않았다. 삭제된 문서는 `DOCS83047A` 기록을 따른다.

## 2026-08-30 DOCS83044A · 문서 기준 및 최신 검증

- 개발 문서는 Taption Plan의 구현·기획·검증·인계에 직접 쓰이는 자료만 유지한다. `AGENTS.md`, `README.md`, `DEVELOPMENT.md`, `NEXT_CHAT_PROMPT.md`, `plan.md`, `SENSOR_FUSION_SOURCES.md`, `STICKMAN_ANIMATION_GUIDE.md`, `design-qa.md`, `temp.md`, `test.md`는 현재 기능 또는 개발 운영을 설명하므로 보존한다. `README.md`가 참조하는 `ui-draft-iphone.html`도 보존한다.
- 프로젝트와 무관하거나 현재 개발 범위를 벗어난 문서는 `DOCS83047A`에서 삭제했다. 판단이 불명확한 자료는 삭제하지 않는다.
- 자동 검증은 `TaptionActivityEngine` 6/6, `TaptionPlanCore` 36/36, `TaptionRouteEngine` 14/14 통과이며 `TaptionPlanEngine`은 소스 빌드와 테스트 target 없음 확인을 완료했다. `git diff --check`도 통과했다.
- iPhone 14 Pro Debug build·설치·실행·readback은 `com.taption.plan` `1.0 (118)`로 통과했다. Watch Debug build와 `com.taption.plan.watchkitapp` `1.0 (118)` 설치·실행 readback도 통과했다.
- 전체 XCTest의 직전 동일 checkout 실행은 XCTest 820건과 Swift Testing 15건, 실패 0건이다. 이번 재시도는 Swift frontend 컴파일 정체로 exit 75 중단되어 새 성공 증거로 대체하지 않는다.
- 실기기 화면·터치, 날씨 범위/갱신, 목요일 경로·졸라맨, Dynamic Island, Watch raw/provenance 동기화, DB cold/warm p95는 `temp.md` 11개 잔여 게이트와 `test.md`에 미완료로 유지한다. 원본 센서·Watch 데이터와 WBS 저장소는 수정하지 않는다.

## 2026-08-19 Map Home·보안·경로 갱신

- 확대된 시간 레일은 플레이헤드를 화면의 고정 위치에 두고 시간 축·세그먼트·경로 축만 스크롤한다. 플레이헤드 아래의 시간이 바뀌면 해당 시각의 저장 위치를 다시 조회해 지도 위치를 갱신한다.
- 과거 날짜의 경로는 현재 시각으로 잘라내지 않고 해당 날짜의 종료 시각까지 투영해 누적 경로를 표시한다. 원본 GPS가 있는 구간만 경로로 연결하고 원본 데이터는 보존한다.
- Face ID 시스템 인증 중 발생하는 `inactive → active` 전환을 새 잠금 진입으로 처리하지 않아 인증 재시도·재잠금 루프를 방지한다. 실제 백그라운드 복귀 잠금은 유지한다.

### 이번 검증

- `TimeScaleTests`, `RouteTimelineDataTests`, `SecurityBackupCoreTests` 선택 테스트 통과
- iOS Debug 빌드 통과
- iPhone 14 Pro에 `com.taption.plan` 설치 및 실행 확인

다음 채팅에서는 실기기에서 확대 레일의 고정 플레이헤드·시간별 지도 위치 갱신과 과거 경로 표시를 직접 재확인하고, 새 기능 수정 시 관련 테스트와 Debug 빌드를 함께 실행한다.

## 자동 기록 파이프라인

원본 센서와 HealthKit 자료는 수정하지 않고 다음 순서로 파생 기록을 만든다.

```text
iPhone GPS/Core Motion + Apple Watch 센서
        ↓
세션별 정규화·정확도 필터·중앙값 보정
        ↓
층수/장소 보정 + 이동수단 판정
        ↓
일간 시간표·상세 카드·Apple 지도 경로
```

### 고도와 층수

- `CLFloor`는 한 번의 값으로 확정하지 않고 같은 층이 연속으로 확인될 때만 전이를 만든다.
- GPS 수직·수평 정확도, 기압, 상대고도, 보행 계단 카운터를 함께 사용한다.
- 상대고도와 기압은 같은 `altimeterSessionID` 안에서만 중앙값을 계산한다.
- 등록 장소에 사용자가 지정한 기준 층이 있으면 자동 추정값으로 덮지 않는다. 실제 층 이동은 별도의 안정화된 전이로 기록한다.
- 원본 `SensorReading`은 보존하고 `PlaceStay.floor`, `FloorTransition` 같은 파생값만 재계산한다.

### 지하철 이동

- `SubwayStationCatalog`은 국내 도시철도 노선 순서와 역 좌표를 보관한다.
- 역 근접성, 철도 경로, GPS 약화, 상대고도 하강, 걸음 수, Apple Watch 진동을 결합한다.
- 두 역 이상이 시간순으로 확인되면 노선 그래프에서 최단 경로와 환승역을 계산한다.
- 지도에는 역 핀과 역 좌표를 잇는 파생 경로선을 표시한다. 원시 GPS는 별도로 보존한다.
- 현재 검증 경로: `마곡나루 → 검암(환승) → 가정` = `공항철도 → 인천2호선`.

## 코드 리뷰 기준

- 센서 원본과 사용자 편집값을 섞지 않는다.
- 반복 계산은 세션·노선 카탈로그를 재사용하고, 고빈도 제스처에서 전체 시간표를 다시 계산하지 않는다.
- 자동 판정은 근거 문자열을 함께 저장하고, 확정되지 않은 값은 낮은 신뢰도로 표시한다.
- iCloud 진단 로그는 개인정보 보호상 좌표와 원시 건강값을 포함하지 않는다. 과거 경로 복구에는 원시 센서 저장소가 필요하다.

### iCloud CloudKit Production

- iCloud Drive의 진단 로그가 내려오는 것과 CloudKit 동기화 스키마가 배포된 것은 별개다.
- `iCloud.com.taption.plan` Production 환경에 `TaptionSnapshot` 레코드 타입과 `schemaVersion`, `updatedAt`, `payload`, `payloadAsset` 필드를 배포한 뒤 TestFlight 빌드를 검증한다.
- 스키마가 없으면 앱은 로컬 저장을 계속하고 설정에 `서버 설정 필요`를 표시하며, 오류 유형·코드만 진단 로그에 남긴다. 스키마 배포 후 설정의 iCloud 행을 눌러 재시도한다.

## 검증

```sh
xcodebuild test \
  -project TaptionPlan.xcodeproj \
  -scheme TaptionPlan \
  -destination 'platform=iOS Simulator,id=81DFCD1F-F2FA-48FC-8DFE-F43DD6D1637A'

xcodebuild build \
  -project TaptionPlan.xcodeproj \
  -scheme TaptionPlan \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

실기기 설치는 Xcode에서 연결된 iPhone을 대상으로 수행한다. 설치 성공은 시뮬레이터 빌드 성공과 별도로 기록한다.

## 2026-08-23 REFA042A01 리팩토링·릴리스 기록

이번 요청은 센서 수집과 보안 경로처럼 장애 비용이 큰 부분을 먼저 고친 뒤,
반복 계산·강제 언래핑·릴리스 문서를 정리하는 순서로 처리했다.

### 우선순위 10개

1. 배터리 절약 센서 간격과 전원 정책을 실제 계약(15분·동작 센서 비수집)에 맞춤
2. 백그라운드 센서 샘플을 시간 경과가 아니라 보관 완료 토큰으로 확인
3. 포그라운드·백그라운드의 센서 시작/복구 순서를 한 메서드로 통합
4. 위치 이벤트로 재실행된 앱을 별도 BGTask 사유로 기록
5. PIN·CloudKit·생체키 생성에서 빈 버퍼 강제 언래핑 제거
6. 백업 암호화 키 생성 실패를 0 바이트 키로 진행하지 않고 오류로 중단
7. 경로·집계·팔레트·축 눈금의 강제 언래핑 제거
8. NLE 테스트의 불필요한 `var` 경고 제거
9. 포그라운드/자정 백업의 중복 처리와 진단 이벤트 통합
10. Debug·XCTest·archive/export·TestFlight를 독립 게이트로 문서화

### 코드 리뷰에서 다음 채팅으로 넘긴 항목

- `MapHomeView`·`AppModel`의 대규모 파일 분해는 동작 회귀 범위가 커서 별도 단계로 유지한다.
- 센서 분류 결과를 Dynamic Island에 실시간 반영하는 coordinator는 제품 상태 계약과
  실기기 확인이 필요하므로 이번 릴리스에는 추가하지 않는다.
- 앱 아이콘과 햄버거 홈 아이콘의 바이너리 해시가 다른 문제는 동일 이미지 교체 후
  시각 검증을 포함한 별도 asset 작업으로 남긴다.
- iOS가 강제 종료된 앱을 임의로 재실행하지 않는 제한과 BGTask의 최소 실행 시각은
  제품 문구·QA에서 “백그라운드”와 “스와이프 종료”를 분리해 설명한다.

### 검증 결과

- `git diff --check`: 통과
- iOS Simulator Debug build (`REFA042A01` DerivedData): `BUILD SUCCEEDED`
- XCTest 대상 실행: 두 시뮬레이터에서 테스트 러너가 연결 전 부트스트랩 크래시를 내어
  테스트 본문은 실행되지 않았다. 동일한 환경의 기존 전체 실행 기준은 505개 통과이며,
  CloudKit 복구는 시뮬레이터 entitlement 환경에서 별도 실패한다.
- 직전 TestFlight build 71은 운영 AdMob ID·무알파 앱 아이콘·배포 서명을 확인해 업로드했고,
  이번 변경을 포함한 build 72도 같은 검증을 거쳐 업로드했다.

### 다음 릴리스 게이트

1. `main` 커밋 후 원격 SHA 확인
2. Release archive/export에서 build 72, 운영 AdMob ID, 무알파 아이콘, Apple Distribution 서명 확인
3. IPA를 App Store Connect에 업로드하고 Delivery UUID·처리 상태 기록
4. 연결된 iPhone 설치·실행은 TestFlight 처리 완료와 별도로 확인

### build 72 업로드 결과

- Delivery UUID: `58eaab2b-f245-4b90-800e-a07f3ecddc3b`
- App Store Connect 업로드: 성공
- 현재 처리 상태: `PROCESSING` (TestFlight 노출 전)

## 2026-08-23 build 74 Pro·지도·센서 릴리스

- 사용자 추가 지하철역과 지하철 Wi-Fi 증거를 이동 판정 우선순위에 반영했다.
- 지도 길게 누르기 후 지하철역·버스 정류장을 추가하면 위치 이름 편집 화면으로 바로 연결한다.
- GPS 기록 간격에 1초·10초·30초를 추가하고 지도 상세도·축소 반응·시간 레일 표시를 정리했다.
- 광고 SDK·광고 설정·배너 영역을 제거하고 14일 앱 자체 체험과 `com.taption.plan.pro` 비소모성 영구 구매·복원을 추가했다. 체험 시작은 Keychain과 iCloud KVS에 보존하며 가장 이른 시작 시각과 가장 늦은 관측 시각으로 재설치·시계 역행을 방어한다. 기존 기록도 `startedAt` 기준 14일로 재계산한다.
- C2 고양이 벡터 아이콘을 iPhone 일반·다크·틴트와 Watch 아이콘에 동일 원본으로 반영했다.
- `BATCH2WK01`에서 지도 오버레이 핀치 전달·위치 추가 취소·저장 위치 이동/편집·사용자 위치 관리 UI·실제 헤딩 나침반·선택 날씨 배경을 통합했다.
- CloudKit 비공개 복구 백업은 계정 복구 키를 먼저 가져와 아카이브 키를 감싸도록 수정했다.

### 검증 및 배포

- 전체 XCTest: 518/518 통과, 실패·스킵 0; Pro 14일 경계·기존 만료 기록 재계산·시계 역행, 나침반·핀치·저장 위치·날씨 상태 회귀 테스트 포함
- iOS Simulator Debug build 통과
- iPhone 14 Pro 설치·실행·readback: `1.0 (74)`
- 기능 소스 커밋: `a2e3c5b`, `origin/main` 푸시 확인
- Release IPA: Apple Distribution 서명, build 74, iCloud KVS 권한 포함, GoogleMobileAds 미포함, 앱 아이콘 1024px·무알파 확인
- TestFlight 업로드 성공: Delivery UUID `bd78668d-fb43-40dd-9d32-5ac0817dcdf1`
- 처리 상태: `VALID`
- 내부 그룹: `TP Taption Plan 내부 테스트`에 build 74 자동 연결, 그룹 관계에서 build 74 노출과 내부 테스터 1명 확인

### 남은 외부 게이트

App Store Connect의 Paid Apps Agreement는 `신규` 상태이며 법인 정보 업데이트 후 계약·세금·은행 정보 완료가 필요하다. 이 절차 전에는 실제 US$0.99 비소모성 상품 생성과 TestFlight 구매 성공 검증을 완료할 수 없다. 로컬 StoreKit 구성과 앱 내 결제 경로는 준비되어 있다.

## 2026-08-24 build 77 다방면 코드 리뷰 릴리스

- 1초 GPS 경로 투영의 반복 전체 스캔과 누적 배열 복사를 제거하고, 경로 오버레이를 캐시해 재생 입력을 24Hz 예산으로 제한했다.
- 분류 시작·자정·DST 하루 끝 경계와 비유한 GPS 정확도·고도 값을 보정했다.
- 지도 컨트롤의 길게 누르기 충돌과 Safe Area 좌표계 불일치를 수정했다.
- 앱 잠금 시 iPhone Widget·Watch·Live Activity의 민감 정보를 숨기고, iCloud 복구 키의 평문 문서 fallback을 제거했다.
- 신규 PIN은 PBKDF2-HMAC-SHA256 600,000회로 파생하며 기존 verifier는 호환 유지한다. 난수 생성 실패는 fail-closed 처리한다.
- 전체 XCTest 576/576, 정적 분석, iPhone·Widget·Watch Debug 빌드와 Release archive/export를 통과했다.
- iPhone 14 Pro에는 직전 `1.0 (76)` 설치·readback이 완료됐다. build 77 Debug 설치는 기기 잠금으로 개발자 이미지 마운트가 거부되어 재시도가 필요하다.
- TestFlight Delivery UUID: `f962c2b8-f430-44e0-88a8-0a00b7b489c4`; 처리 상태 `VALID`/`제출 준비 완료`.
- `TP Taption Plan 내부 테스트` 그룹 관계와 App Store Connect 실제 화면에서 build 77 노출을 확인했다.

## 2026-08-25 build 88 센서·경로·스플래시 통합

- GPS와 센서 수집 프로필을 정확도 우선·1초 간격으로 고정했다. 저장돼 있던 이전 간격과 배터리 최소 설정도 앱 로드·동기화 시 실시간 기준으로 정규화한다.
- 위치 항상 허용·정확한 위치·동작·HealthKit·사진·캘린더·알림·앱 사용 기록·Live Activity 권한을 `RequiredPermissionGate`로 확인한다. 빠진 권한이 있으면 메인 기록 화면을 잠그고 권한 카드에서 요청 또는 시스템 설정으로 이동한다.
- 이동 경로가 저장된 GPS에 없거나 비어 있는 구간은 `MKDirections` 예상 경로를 화면 표시용으로 계산한다. 자동차·택시·버스는 자동차, 지하철·기차는 대중교통, 걷기·자전거·달리기는 도보 경로를 사용하며 확정된 지하철 노선 경로와 원본 센서 자료는 우선·보존한다.
- 예상 경로는 요청 단위 캐시와 선택 시각 절단을 사용하고, 경로가 없을 때 지도 자동 카메라가 현재 위치로 되돌아가지 않도록 지도 중심 계산에 함께 반영한다. 지도 단일 손가락 이동 시작은 즉시 현재위치 추적을 해제한다.
- 과거 위치 마커는 분홍색 팬토그래픽 사람 모양으로 표시하고 접근성 라벨을 유지한다.
- 기존 앱 아이콘 스타일과 배경은 유지하면서 새 `TaptionPlanLaunchCat.svg`에 몸통·앞발·뒷발·수염을 추가했다. SwiftUI 오버레이용 투명 `LaunchIcon`과 네이티브 시작 화면용 불투명 `NativeLaunchIcon`을 분리해 동일한 중앙 배치를 사용한다.

### 검증 및 기기 설치

- 전체 XCTest: 636/636 통과
- iOS Debug 빌드: 통과
- 연결된 iPhone 14 Pro에 현재 작업본 설치·실행: `com.taption.plan` `1.0 (88)`
- 기기 프로세스 readback: `TaptionPlan` PID `49149`
- `git diff --check`: 통과
- 이번 배치에서는 TestFlight archive/upload를 수행하지 않았다. App Store Connect Paid Apps Agreement `신규` 및 실제 `com.taption.plan.pro` 상품 생성 게이트는 계속 `IAP73PAID1`로 유지한다.

## 2026-08-26 경로·분류 잠금·NLE 반응성 통합

- `TaptionPlanCore`는 일자 단위 SQLite 저장소와 generation 기반 NLE 입력 예산을 제공한다. 고빈도 제스처 입력은 최대 60Hz로 제한하고 제스처 종료 최종값은 즉시 반영한다.
- `TaptionActivityEngine`은 상세·대분류 taxonomy와 센서 근거 분류를 담당하며, 자동 생성된 수면·이동·HealthKit·위치·지하철 분류와 `TravelSegment`는 저장 후 다시 분류되지 않는다. 사용자 편집만 저장된 결과를 덮어쓰며 원본 센서 자료는 보존한다.
- `TaptionRouteEngine`은 동일 시각 중복 우선순위, 2D constant-velocity Kalman 필터, 정지 드리프트 억제, 정확도 경계, 불가능한 점프·15분 공백 세그먼트 분리와 RDP 표시 축약을 담당한다.
- 앱 시작은 로컬 스냅샷과 일자 데이터를 먼저 hydrate한 뒤 홈을 연다. 사이드바·경로·지도 파생값은 캐시하고 드래그 중 전체 일자 재계산을 피한다.
- 지도 현재·과거 위치는 MapKit의 투명 위치 앵커를 따라가는 SwiftUI overlay 졸라맨으로 표시해 모든 지도 annotation보다 앞에 둔다. 추적 중 선택 시각 위치를 중앙에 유지하고, 지도 이동 시 추적을 해제하며 핀치 줌·사이드바 핸들의 터치 영역을 확장했다.
- 지하철 확정 구간은 저장된 선로 기반 확정 경로와 분류를 유지한다. 예상·점선 경로 오버레이는 비활성화했다. 재생 속도는 걷기·달리기는 빠르게, 자동차·자전거·지하철·기차·배·비행기는 느리게 적용한다.
- GPS·센서 수집 간격 슬라이더를 복원했다. Dynamic Island 우측 파형은 GPS 주기의 절반을 전체 폭으로 사용하고 실제 센서 저장 시 ECG 1회 펄스 후 평선으로 돌아간다. 1초 주기에서는 시간 진행을 표시하지 않는다.

### 검증 및 배포

- 전체 XCTest: 695/695 통과, 실패·스킵 0
- `TaptionPlanCore`: 24/24, `TaptionActivityEngine`: 4/4, `TaptionRouteEngine`: 11/11 통과
- iOS Simulator Debug build: 통과
- 서명된 iPhone Debug build: build 95로 통과
- iPhone 14 Pro 설치·실행·readback: `com.taption.plan` `1.0 (95)`, `TaptionPlan` PID `55910`
- `git diff --check`: 통과
- 이번 배치에서는 TestFlight archive/upload를 수행하지 않았다.
- Paid Apps Agreement·세금/은행 정보·실제 `com.taption.plan.pro` 상품 생성과 Sandbox 구매·복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 build 96 경로·센서·UI 통합 TestFlight

- Release archive/export: `1.0 (96)`, `com.taption.plan`, Apple Distribution 서명, IPA 검증 성공
- TestFlight 업로드 성공: Delivery UUID `932ca076-b9ed-4a5f-9598-c7ba2c45b2f9`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`
- `TP Taption Plan 내부 테스트` 그룹에 build 96 연결 및 그룹 builds 관계 노출 확인
- 이번 빌드의 실기기 설치·실행은 별도 게이트로 남긴다.

## 2026-08-26 build 97 엔진·저장소·실시간 UI 통합

- `TaptionPlanEngine` umbrella Swift Package를 추가하고 Core·Activity·Route 엔진의 공개 경계를 하나로 묶었다.
- SQLite 정본과 센서·지도 캐시의 Codable payload를 binary plist + LZFSE(가능한 경우) + 원본 바이트 수 + SHA-256 envelope로 통일했다. 이전 JSON payload는 호환하지 않는다.
- 일자 데이터·지도 캐시에 bounded LRU와 지연 로딩·메모리 압력 축출을 적용하고, NLE 파생 projection은 generation으로 오래된 계산을 폐기한다.
- GPS 임시 역 위치, 지하철 확정 경로, 속도 기반 경로 팔레트, 현재 위치 전면 annotation, 날씨·미세먼지 색상, 시작 화면 `Taption Plan`/0–100% 진행 표시, 첨부 고양이 아이콘·스플래시를 통합했다.
- Dynamic Island는 우측에서 좌측으로 흐르는 파형만 표시하며 센서 저장 시 1회 ECG 펄스 후 평선으로 돌아간다. 외부 수신 센서는 지원된 provenance일 때만 빨간색으로 표시하고, 우측 상단 2px 단일 점을 1초 주기로 점멸한다.

### 검증 및 배포

- `TaptionPlanCore`: 28/28, `TaptionActivityEngine`: 4/4, `TaptionRouteEngine`: 11/11, 앱 XCTest: 695/695, 어댑터 Swift 테스트: 10/10 통과
- iOS Simulator Debug build: `BUILD SUCCEEDED`
- Release archive/export: `1.0 (97)`, `com.taption.plan`, IPA 검증 성공 (`d8f6ab1d458daecf4df5a2ddacc2b32a4d7793207e2c9e0f4f4d508b34d2b5bb`)
- TestFlight 업로드 성공: Delivery UUID `785306ae-b642-4679-a0ed-123ca25e1565`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`, `IS-ON-APP-STORE-CONNECT: true`
- `TP Taption Plan 내부 테스트` 그룹에 build 97 연결, builds 관계에서 build 97 노출 확인
- 실기기 설치·실행·readback은 별도 게이트이며, 다른 앱의 센서 사용 감지는 iOS 공개 API 제한으로 추정하지 않는다.
- Paid Apps Agreement·세금/은행 정보·실제 `com.taption.plan.pro` 상품과 Sandbox 구매·복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 WXHIDE97A1 날씨 카드 완성 스냅샷 게이트

- 시간 레일 핸들 왼쪽에 붙던 compact 날씨 케이스를 제거했다.
- 날씨 카드는 수집 시각·비 stale 상태·조건·심볼·유한 온도가 모두 준비된 스냅샷만 표시한다. 미세먼지 응답이 포함된 경우 PM10·PM2.5·제공자도 유효해야 하며, 부분 응답은 카드 전체를 숨긴다.
- `TimeScaleTests` 111/111 통과, iOS Simulator Debug build 성공.
- build 97에는 포함되지 않았고 아래 build 98 TestFlight에 포함했다.

## 2026-08-26 build 98 날씨 게이트 TestFlight

- Release archive/export: `1.0 (98)`, `com.taption.plan`, Apple Distribution 서명, IPA 검증 성공 (`15f52d1ef05620b71189c6e1806bf0a5e3642878cb15c5be7325ff4ba595e876`)
- TestFlight 업로드 성공: Delivery UUID `e5c531e6-6f53-41ab-b6e7-982e73a626c6`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`
- `TP Taption Plan 내부 테스트` 그룹 연결 및 그룹 빌드 목록에서 build 98 노출 확인
- 실기기 설치·실행·readback은 별도 게이트로 남긴다.

## 2026-08-26 build 99 센서·메뉴·백업 게이트 TestFlight

- Release archive/export: `1.0 (99)`, IPA SHA-256 `6701314b618ac7c452e60f1ab285b163a07dad8697df771c4bd35921acb44dde`
- TestFlight 업로드·처리 상태 `VALID` 확인, `TP Taption Plan 내부 테스트` 그룹 연결 및 build 99 노출 확인
- GPS 주기 설정 저장·수집 주기 동기화, 미세먼지 기반 날씨 색상·사용자 팔레트·백업 최근 날짜·메뉴 축소를 포함한다.

## 2026-08-26 build 100 센서 복원·날씨 캐시·식당 분류 통합

- 위치 백업 경로 투영에 비현실적 GPS 도약·정확도 필터를 적용하고 원본 센서 아카이브는 보존한다.
- 복원 후 지하철 이동을 재분류·병합하고 확정 이동은 유지한다. 오늘 수면 조회 구간은 전날 18:00부터 당일 12:00까지로 고정했다.
- 날씨 완성 스냅샷을 로컬 캐시해 시간 사이드바 조절 후에도 표시를 유지한다.
- 식당 장소를 여러 곳 등록할 수 있고 15분 이상 체류만 식사로 분류한다. 식당 아이콘·색상·편집 UI를 연결했다.
- Dynamic Island 확장 파형은 전체 폭을 우→좌로 흐르고, compact 좌·우 영역은 연속 위상을 공유한다. 센서 주기 절반 동안 ECG 펄스가 진행되고 우측에만 2px 로깅 점이 점멸한다.

### 검증 및 배포

- 전체 XCTest 성공(실패·스킵 0), iOS Simulator Debug build 성공
- Release archive/export: `1.0 (100)`, Apple Distribution 서명, IPA SHA-256 `7a38f3a513a3b050c2defaee9253994d89b81f3b9af27162ed4583616a74d1e8`
- TestFlight 업로드 성공: Delivery UUID `9daf4383-c3d7-499d-b7a3-1e158b8b27c0`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`
- `TP Taption Plan 내부 테스트` 그룹에 build 100 연결 및 그룹 builds 관계 노출 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 build 101 식당·수면·Dynamic Island 수정 TestFlight

- 등록 식당 체류를 15분 이상일 때 `식사`로 자동 분류하고 여러 식당·수동 식사 기록을 보존한다.
- 오늘 센서 원본을 전날 18:00부터 당일 12:00까지 다시 분석해 수면 결과를 갱신하고, 데이터가 부족하면 기존 결과를 보존한다.
- 식당 위치 아이콘의 일반 사용자 지점 라벨을 식당으로 보정하고, Dynamic Island 파형 이동·평선·2px 스캔 효과를 반영했다.

### 검증 및 배포

- 전체 XCTest 성공(실패·스킵 0), iOS Simulator Debug build 성공
- Release archive/export: `1.0 (101)`, Apple Distribution 서명, IPA SHA-256 `4a47982d8e89cd64ac58f0ade6c645abf4b450144c2b17af55a77e08349f572d`
- TestFlight 업로드 성공: Delivery UUID `f8661c57-3157-41e3-9e86-dcb295ee3215`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, Apple ID `6797370230`
- `TP Taption Plan 내부 테스트` 그룹에 build 101 연결 및 그룹 builds 관계 노출 확인
- 기능 커밋 `2c1278d`, `origin/main` 푸시 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-26 build 102 센서 상태 미터·Dynamic Island 파형 TestFlight

- 센서별 최근 10개 수집 상태를 누적 미터로 표시하고 수집·지연·대기 상태를 구분한다.
- Dynamic Island 확장 영역 전체에 무노이즈 파형과 1초 스캔 효과를 적용하고 센서 저장 시 펄스를 반영한다.

### 검증 및 배포

- 센서 미터·상태·1초 파형 주기 XCTest 3건 통과, generic iOS Release archive 컴파일 통과
- Release archive/export: `1.0 (102)`, Apple Distribution 서명, IPA SHA-256 `47d417a4d51758f514c105ab3a3ec7ff578370ac052d91cf3dd195a616de0ee9`
- TestFlight 업로드 성공: Delivery UUID `9bec24ce-e0da-4868-8398-5c75e8b3421b`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, Apple ID `6797370230`
- `TP Taption Plan 내부 테스트` 그룹에 build 102 연결 및 그룹 builds 관계 노출 확인
- 기능 커밋 `16d864b`, `origin/main` 푸시 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-27 Dynamic Island 앱 아이콘·재생 경로 마무리

- `SensorCollectionLiveActivity`의 Dynamic Island 확장형 leading 영역에 `SensorCollectionAppIcon`을 연결했다.
- compact leading은 센서 수집 중 항상 앱 아이콘을 렌더링하고 비수집 상태에는 고정된 투명 프레임을 사용해 회색 플레이스홀더가 나타나지 않게 했다. compact trailing 심박 HUD의 기존 10초 표시 정책은 유지한다.
- 위젯 전용 `SensorCollectionAppIcon` 리소스가 `Assets.car`에 포함되는 것을 확인했다.
- 재생 시작 시 기존 경로 투영을 비우고 원본 센서 읽기를 다시 준비하며, 재생 중 플레이헤드가 이동할 때마다 경로·현재 위치를 갱신해 시간에 따라 경로가 생성되도록 했다. 경로 절단 시각은 선택된 플레이헤드를 상한으로 사용한다.

### 검증 및 설치

- `git diff --check`: 통과
- `TaptionPlanWidget` Debug 시뮬레이터 빌드: 성공
- 서명된 iPhone Debug 빌드: `1.0 (102)` 성공
- 연결된 iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`)에 `com.taption.plan` 설치·실행 성공
- `origin/main` 푸시 커밋: `5bcd766 fix: show app icon in sensor live activity`
- 실기기 앱 설치·실행은 확인했지만 Dynamic Island 확장/축소 터치와 센서 실시간 렌더링은 별도 수동 게이트로 남긴다.

### 저장소 정리

- 이번 작업에서 생성한 실기기 빌드 산출물과 오래된 Taption Plan DerivedData·임시 테스트 캐시를 삭제했다.
- 테스트 결과·릴리스 아카이브·시각 QA 증거와 다른 프로젝트가 공유하는 시뮬레이터 데이터는 보존했다.
- 현재 Git 워크트리는 clean이며 `main`과 `origin/main`이 일치한다.

## 2026-08-27 HZ240827A1 240Hz 입력 예산 전수 점검

- `TimelineInteractionFrameGate`에 240Hz 입력·60Hz 표시 기준과 zero timestamp 중복 발행 방지를 명시했다.
- MiniTimeSliceEditor·TimeSlider·메모·실제 기록 핸들·상세 패널·LocationTimeline·MapHome 보조 제스처의 중간 상태 변경을 60Hz로 합치고, 제스처 종료값은 즉시 반영한다.
- 재생 중 경로 투영과 지도 포커스는 각각 30Hz로 제한하고, 기존 NLE·MapKit·구간 경계·Review 게이트를 유지했다.

### 검증

- `TimeScaleTests` 전체가 `Taption-Compact-iPhone` 시뮬레이터에서 `TEST SUCCEEDED`로 통과했다. 240Hz 입력→60Hz 표시와 30Hz 재생 카메라 계약 테스트를 포함한다.
- `TaptionPlanCore` `CoreEngineContractsTests` 8/8 통과, synthetic 240Hz handler p95 `0.000042ms`로 입력 예산 4.17ms 이내다.
- `git diff --check`: 통과
- 최종 변경의 테스트 빌드 컴파일은 성공했으나, 별도 Debug 링크 재빌드는 호스트 여유 공간 108MiB에서 `errno=28`로 중단됐다. 실기기 Animation Hitches/Instruments와 실제 터치 검증은 별도 런타임 게이트로 남긴다.

## 2026-08-27 build 103 균형형 백그라운드 경로 보정 TestFlight

- 균형형 GPS 프로필의 자동 이동 승격을 실시간·균형형 주기에 맞게 허용하고, 10초 후보 판정이 끝나기 전에 샘플링 스트림이 종료되지 않도록 보정했다. 이로써 백그라운드 경로의 불필요한 공백을 줄인다.
- 기존 Dynamic Island 앱 아이콘 변경을 함께 포함해 compact·expanded 표시에서 회색 플레이스홀더 대신 앱 아이콘을 사용한다.

### 검증 및 배포

- `FeatureEngineTests.testAutomaticTrackingPromotionAndStopPolicy` 통과, 전체 앱 XCTest `test-without-building` 종료 코드 0, iOS Simulator Debug build 성공
- Release archive/export: `1.0 (103)`, `com.taption.plan`, Apple Distribution 서명, IPA SHA-256 `1dd71f0b94415a27aa6dd6053aef972a12357b26e4dfccea4132efac3716ab51`
- TestFlight 업로드 성공: Delivery UUID `a14a666d-08b0-4ec2-b510-7e40aa73feae`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, Apple ID `6797370230`
- `TP Taption Plan 내부 테스트` 그룹에 build 103 연결 및 그룹 builds 관계에서 build 103 노출 확인
- 기능 커밋 `2d6ae63`, `origin/main` 푸시 확인
- 실기기 설치·실행·readback은 별도 게이트이며 Paid Apps Agreement·상품 생성·Sandbox 구매/복원은 `IAP73PAID1` 외부 게이트로 유지한다.

## 2026-08-27 I143RAWLOG 예상경로·센서 raw iCloud 분리 저장

- 오늘 iCloud 백업의 09:28:33~11:00:59 지하철 이동에는 정밀 iPhone GPS 원본이 있었지만, 대중교통 판정 플래그·확정 지하철 경로·역 근거가 없었다. 따라서 예상경로 조건은 충족했는데 `MapHomeView`의 `Map` 콘텐츠에 계산된 `visibleExpectedRouteOverlays`를 삽입하지 않아 표시되지 않았고, 초기 센서 읽기 완료 뒤 재요청도 없어 첫 로드에서 누락될 수 있었다.
- 예상경로를 점선 `MapPolyline`으로 지도에 렌더링하고, 센서 읽기 병합 후 예상경로 갱신을 다시 요청하도록 수정했다. 확정 지하철 경로와 예상경로의 표시 경계는 유지한다.
- 기존 월간 계획 백업과 분리해 `iCloud Drive/Taption Plan/Raw Sensors/YYYY-MM.rawsensorbackup`에 저장한다. 저장 대상은 영구 보존된 비HealthKit 센서 읽기·raw envelope이며, AES-GCM·TPZ1/LZFSE·SHA-256 무결성·iCloud 계정 복구 키를 사용한다. HealthKit 원본과 Apple Watch 건강 스냅샷은 저장하지 않는다.

### 검증

- iCloud 백업·진단·센서 DB 읽기 전용 대조: 오늘 route point 152개, 가장 긴 GPS 공백 약 64분 44초, `TaptionLogs` 파일 없음, 지하철 구간은 미확정·대중교통 플래그 없음
- `RouteTimelineDataTests` 및 `SecurityBackupCoreTests` 대상 XCTest 성공
- raw 암호화·분리 경로·HealthKit/Watch 건강 스냅샷 제외 회귀 테스트 성공
- iOS generic Debug build 성공, `git diff --check` 통과

## 2026-08-27 STICK827C3 졸라맨 지도 재생·경로 미리보기

- 회사는 컴퓨터·책상, 학교는 독서·책상, 수면은 침대·`zzz`, 식사는 식탁, 걷기·자전거·자동차·버스·2량 지하철 탑승을 단순 선화 Canvas 포즈로 표시한다.
- 현재 시각과 하루 재생 플레이헤드에서 같은 상태 판정기를 사용하고, 재생 중 30Hz fractional 시각으로 포즈·현재 위치를 함께 갱신한다. Reduce Motion에서는 정지 포즈를 사용한다.
- Taption WBS의 지도 재생 방식을 적용해 확정 지하철 경로는 역 좌표 투영을 사용하고, 일반 경로는 기존 RouteTimeline projection과 MapKit 예상경로를 공유한다. 예상경로는 도로 경로가 준비되기 전에도 시작·끝 직선 fallback을 표시하며, 부분 경로는 정점 개수가 아닌 거리 기준으로 절단한다.
- 기존 `RouteSpeedGradient` 속도별 색상, 실제·예상 경로 구분, 원본 센서·기록은 변경하지 않았다.
- 회사 위치가 새로 업무로 확정됐을 때 이전 `unknownStay` 자동분류 잠금이 덮어쓰지 않도록 보정하고, 사용자 수동 분류 잠금은 유지한다.

### 검증

- `MapHomeStickmanTests`, `RouteTimelineDataTests`, 회사 `unknownStay` 잠금 회귀 테스트 성공
- iOS generic Debug build 성공, `git diff --check` 통과
- Debug 앱을 iOS Simulator에 설치·실행했으나 지도 진입 전 `14일 무료 체험` 화면에서 멈췄다. 구매·구독 동작은 실행하지 않아 지도·실제 터치 시각 검증은 별도 게이트로 남긴다.

## 2026-08-27 build 104 파스텔 MapHome 활동 UI TestFlight

- 흰색 시간 사이드바·인접 날씨·기존 왼쪽 하단 네 가지 컨트롤을 유지하면서 MapHome 색상과 카드·버튼을 파스텔 조합으로 정리했다.
- 대분류 활동 핸들을 선화 졸라맨 포즈로 표시하고 회사·학교·수면·식사·걷기·자전거·자동차·지하철 상태별 애니메이션을 재생 시각과 현재 시각에 공통 적용했다.
- 240Hz 제스처 입력·60Hz 화면 갱신·30Hz 재생 경계를 유지하고 실제·예상 경로와 속도별 색상 표현을 보존했다.

### 검증 및 배포

- `FeatureEngineTests`·`TimeScaleTests` 대상 XCTest 581/581 통과, iOS Simulator Debug build 성공
- Release archive/export: `1.0 (104)`, `com.taption.plan`, Apple Distribution 서명, IPA SHA-256 `b5d49cd87d056349cdb5aa983cb3f36412711d26d2bbc43e309c8b3fb185e7a6`
- TestFlight 업로드 성공: Delivery UUID `36e77558-44a9-4389-ac82-d00a245e6078`
- App Store Connect 처리 상태 `VALID` / `APP_STORE_ELIGIBLE`, beta 상태 `IN_BETA_TESTING`
- `TP Taption Plan 내부 테스트` 그룹에 build 104 연결 및 그룹 builds 관계에서 build 104 노출 확인
- main 기능·빌드·서명 수정 커밋 `e579b09`, `f7ed488`, `de21ee4`, `origin/main` 일치 확인
- 실기기 설치·실행·readback은 iPhone 연결·잠금 해제 후 별도 게이트로 남긴다.

## 2026-08-27 build 106 대분류 졸라맨 Dynamic Island 통합

- 첨부 시안은 화면 구성·문구·색상 복제 없이 단순 선화, 얼굴 표정, 준비·이동·동작 원칙만 참고했다.
- 지도·활동 카드·핸들에 공통 얼굴과 표정, 바닥 그림자, 활동별 분주한 Canvas 동작을 적용했다. 회사·학교·수면·식사·걷기·자전거·자동차·버스·2량 지하철·머무름의 의미와 기존 지도 전면 표시·Reduce Motion·30% 축소를 유지한다.
- Live Activity 대분류 상태를 위젯 공유 코드에서 10개 졸라맨 동작으로 해석하고, Dynamic Island compact leading·minimal·expanded leading에서 SwiftUI Canvas 애니메이션으로 표시한다. 기존 타이머·파형·종료 동작은 유지한다.

### 검증 및 배포

- `MapHomeStickmanTests` 및 전체 `TaptionPlanTests`: `TEST SUCCEEDED`
- iOS generic Debug build: `BUILD SUCCEEDED`
- Release archive/export: `1.0 (106)`, `com.taption.plan`, Apple Distribution 서명, IPA SHA-256 `f5d66d090d3eea06e3628ff775ba1698a7289ca80e47ec629fe5cad0ce25aadc`
- TestFlight 업로드 성공: Delivery UUID `41dc832d-5a98-4a77-8122-aad743df6e28`
- App Store Connect 처리 상태: `VALID` / `APP_STORE_ELIGIBLE`, `is-on-app-store-connect: true`, build 106 `제출 준비 완료` 노출 확인
- 기능·빌드 커밋 `b67b9bb`, `origin/main` 푸시 확인
- `TP Taption Plan 내부 테스트` 그룹 연결 완료: 빌드 목록에서 build 106이 그룹에 연결된 것을 확인했다.
- 그룹 화면(`/testflight/groups/b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)의 빌드 탭에서 `1.0 (106)`, `테스트 중`, `iOS` 노출을 확인했다.

## 2026-08-27 ZIDX27A1B2 지도 졸라맨 최전면 고정

- MapKit `Annotation`의 내부 정렬은 SwiftUI `zIndex`로 보장되지 않아 장소·검색 핀이 졸라맨을 가릴 수 있었다. 졸라맨은 지도 내부의 1pt 투명 위치 앵커만 따라가고, 실제 Canvas는 모든 지도 annotation 위의 SwiftUI overlay에서 렌더링하도록 분리했다.
- 앵커 좌표는 240Hz 입력을 직접 상태에 전달하지 않고 최대 60Hz로 합치며, 카메라·타임라인 상호작용 종료 시 최신 좌표를 즉시 반영한다. 검색·사이드바·메뉴·상단 헤더는 기존대로 졸라맨보다 위에 유지한다.

### 검증

- 전체 `TaptionPlanTests` 732/732와 Swift Testing 10/10 통과, iOS generic Debug build 성공, `git diff --check` 통과
- 시뮬레이터에서 현재 위치와 인천광역시청 검색 핀을 같은 좌표에 표시했을 때 두 접근성 요소가 유지되고 화면에는 졸라맨이 최전면으로 표시되는 것을 확인했다. 현재 위치 이동과 연속 확대 뒤에도 표시가 유지됐다.
- iPhone 14 Pro에 `1.0 (106)` Debug 재설치·실행 및 PID 6805 readback을 확인했다. 15초 실행 콘솔에서 기존 `AttributeGraph` cycle 재발은 없었다.

## 2026-08-27 SLEEP827B2 07:15 수면 누락 원본 점검

- 연결된 iPhone 앱 컨테이너의 `sensor-readings-v1.jsonl` 15,826건을 읽기 전용으로 확인했다. 최신 원본은 2026-08-25 22:17:35 KST이며 2026-08-27 07:00~07:30 KST 표본은 0건이다.
- 따라서 앱 센서 원본만으로는 07:15 전후 수면 종료를 재구성할 수 없다. HealthKit 수면 원본은 별도 보관 정책상 앱 raw/iCloud 센서 백업에 포함되지 않고 현재 앱에는 원본 readback 화면이 없어, HealthKit의 실제 종료 시각은 이번 점검에서 확정하지 않았다.

## 2026-08-29 REL29TF7Q2 이동 후보·경로·Watch 동기화 릴리스

- OpenFreeMap/MapLibre 소스와 공개 경계는 보존하되 현재 런타임과 설정 메뉴는 Apple 지도 표준 스타일로 고정한다.
- 지하철역·기차역·버스 정류장·공항·항구 후보는 실제 동력 이동이 끝났고 분류 또는 기록 경로가 불확실한 경우에만 만든다. 확정됐거나 GPS 경로가 완전한 이동은 후보와 점선 예상 경로를 만들지 않는다.
- 오늘 날짜 재생은 현재 시각에서 멈추며 다시 재생하면 자정부터 시작한다. 재생 tick마다 전체 경로를 정규화하지 않고 화면 갱신 예산 안에서 기존 투영을 재사용한다.
- Apple Watch 수신 자료는 iPhone 수신 시각이 아니라 각 payload의 실제 측정 시각을 종류별로 보존한다. 지연·미래·역순 payload가 최근 수신 상태를 거짓으로 갱신하지 않으며 재실행 뒤에도 마지막 측정 시각을 복원한다.
- 12프레임 보행에서 지지 발의 접지 종료를 정확히 7/12 위상에 맞춰 경계 직전의 미세한 발 들림을 없앤다.
- TestFlight 배포 대상은 `1.0 (111)`이다. 직전 build 110은 App Store Connect에 이미 등록돼 있어 재사용하지 않는다.

### 검증 및 배포

- 전체 `TaptionPlanTests` 797/797 통과, 실패·스킵 0; generic iOS Debug build와 `git diff --check` 통과.
- 기능·빌드 커밋 `834a146`을 `origin/main`에 푸시하고 원격 SHA 일치를 확인했다.
- Release archive/export: `1.0 (111)`, `com.taption.plan`, Apple Distribution 서명, Store 프로비저닝, IPA SHA-256 `9699c711070d01b684454541be3043097379e1a032209f1104e95fba36349ea2`; App Store Connect 사전 검증 통과.
- TestFlight 업로드 성공: Delivery UUID `b70dc4c7-06e1-4bc8-85a9-13377ff1dcfa`; 처리 상태 `VALID`, 내부 상태 `IN_BETA_TESTING`.
- `TP Taption Plan 내부 테스트` 그룹에 build 111을 연결했다. 그룹 빌드 화면에서 `1.0 (111) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 `설치됨 1.0 (111)` 노출을 확인했다.
- 실기기 설치·실행·HealthKit/Watch 실제 수신은 이번 TestFlight 업로드와 별도 게이트다.

## 2026-08-29 STK9V6Q2M4 졸라맨 18개 동작 재설계

- `MapHomeStickmanRenderer`의 졸라맨을 기존 Canvas 계약(64×56 좌표계, 진분홍 선화, 12프레임, Reduce Motion)을 유지한 채 관절·얼굴·소품이 함께 보이는 형태로 다시 구성했다.
- 시점은 걷기·달리기·일반 이동·버스·선박·자전거를 옆면, 업무를 오른쪽 사선 뒤, 학교·식사·운동을 왼쪽 사선 앞, 취미·미확인을 정면, 수면을 옆면, 차량을 정면으로 고정한다. 활동은 정면→왼쪽 옆→오른쪽 옆 순으로 12프레임을 순환한다.
- 업무는 모니터의 타이핑 텍스트와 키보드 입력을, 학교는 책·페이지 넘김을, 취미는 마이크·음표·노래하는 입 모양을, 수면은 침대·베개·이불·호흡·Z를, 미확인은 고개 갸웃과 물음표를 표시한다.
- 차량은 운전대와 정면 운전 자세로 통합하고 `자가용` 데이터도 `.car` 렌더링으로 통합했다. 선박은 난간과 물결 흔들림, 비행기는 큰 창과 탑승자, 2량 지하철은 큰 창·앞쪽 정면 승객·손잡이, 버스는 손잡이를 추가했다.
- 자전거는 옆면 페달 회전, 걷기·달리기는 보폭·접지 기반 동작을 유지하며, 모든 이동 동작은 기존 경로·재생 위치 투영과 함께 사용한다.
- 분류 회귀 기대값은 `TaptionPlanTests/FeatureEngineTests.swift`에서 `자가용 → .car`로 갱신했다. Live Activity의 별도 `privateVehicle` 계약은 변경하지 않았다.

### 검증 및 게이트

- 최신 소스 기준 generic iOS Debug build와 iOS Simulator `build-for-testing` 성공, `git diff --check` 통과
- iPhone 14 Pro `MapHomeStickmanTests` 20/20과 앱 실행은 최종 렌더 세부 패치 전 서명 Debug 상태에서 통과했다.
- 최종 렌더 세부 패치 후 동일 테스트 재시도는 iPhone 잠금 상태의 `deviceprep` 차단으로 중단됐다. 따라서 최종 소스의 실기기 화면·터치·동작 시각 검증은 미완료다.
- 현재 환경에는 사용 가능한 iOS Simulator 기기가 없어 Simulator 화면 검증을 완료할 수 없다. TestFlight archive/upload와 내부 그룹 readback은 이번 변경의 별도 미실행 게이트다.
- 새 채팅 인계 프롬프트는 `NEXT_CHAT_PROMPT.md`에 최종 푸시 SHA와 남은 실기기 게이트를 기록한다.

## 2026-08-31 ARC831A001 엔진·센서·저장소 통합 계획

- `TaptionPlanCore`는 Foundation 기반 공유 계약, 정본 payload, SQLite day-store와 원본을 변경하지 않는 범용 센서 품질 판정을 소유한다. 앱·Widget·Watch가 공유하는 App Group 식별자도 Core 계약으로 단일화한다.
- `TaptionActivityEngine`은 확정된 수면·운동·수동·잠금 기록을 hard anchor로 보존하고, 센서 근거가 있는 미확인 구간만 시간 연속성 기반으로 추론한다. 근거가 없거나 충돌하면 미확인으로 남긴다.
- `TaptionRouteEngine`은 GPS 정확도·물리 속도·Kalman innovation gate·정지 드리프트 억제를 하나의 원본 보존형 경로 필터로 통합한다. 경로 공백은 시간·거리·양 끝점·이동수단 근거를 모두 만족할 때만 파생 예상 경로로 연결한다.
- `TaptionPlanEngine`은 세 leaf package의 umbrella 공개 경계로 앱에서 실제 사용한다. MapKit·HealthKit·ActivityKit·CloudKit·SwiftUI 어댑터는 앱 target에 남기고, Widget·Watch target의 대규모 소스 재배치는 이번 안정화 범위에서 제외한다.
- SQLite는 schema 생성을 단일 transaction으로 묶고 raw event batch에 prepared statement를 재사용한다. canonical payload는 최대 크기와 선언된 원본 바이트 수를 검증하며, materialized day는 iPhone·Watch 원본 digest와 일치할 때만 사용한다. startup에는 `PRAGMA optimize`를 적용한다.
- 백업 복원은 staged snapshot을 정본 저장소에 먼저 저장하고 성공 뒤에만 메모리 상태를 publish한다. snapshot과 raw route는 부분 성공 상태를 명시하며, 실패 시 기존 메모리 snapshot을 유지한다. 월별 센서 chunk는 재실행 뒤 기존 번호 다음부터 이어 쓴다.
- 지도·타임라인 UI와 원본 센서·확정 기록은 변경하지 않는다. 각 변경은 package 단위 테스트, 앱 회귀 테스트, Debug build, Release archive 순으로 검증한 뒤 TestFlight 내부 그룹과 테스터 화면까지 readback한다.

### 검증 및 배포

- `TaptionPlanCore` 40건, `TaptionActivityEngine` 8건, `TaptionRouteEngine` 16건, `TaptionPlanEngine` 1건 등 package 65건과 앱 XCTest 848건·Swift Testing 18건이 모두 통과했다.
- generic iOS Debug·Release 빌드와 Release archive/export가 통과했다. 앱·Widget·Watch·Watch Widget은 모두 `1.0 (121)`이며 Apple Distribution 서명, Production iCloud, TestFlight entitlement와 deep codesign을 확인했다.
- 배포 소스 커밋 `53e18940bbf13459927d23053ad783f0b8431294`를 `origin/main`에 먼저 푸시했다. IPA SHA-256은 `3957d7f3800314fc9af6f201a3a4ad3ef20548120f6917072337ef187dffa667`이다.
- TestFlight Delivery UUID `d1cf40bf-7b56-42ef-a7cb-12d82067734c`는 처리 `COMPLETE`, 오류·처리 경고 0, App Store Connect에서 `제출 준비 완료`로 readback했다. MapLibre 외부 framework dSYM 미포함은 심볼 업로드 경고로 별도 기록하며 앱 업로드는 수락됐다.
- `TP Taption Plan 내부 테스트`에 build 121을 연결했다. 그룹 상세는 `내부 그룹 · 1명의 테스터 · 82개의 빌드`, 빌드 탭은 `1.0 (121) · 테스트 중 · iOS`, 테스터 탭은 내부 테스터 1명을 표시한다. 현재 설치 표시는 `1.0 (120)`이므로 build 121 설치·실행·실제 터치와 Apple Watch 현장 수신은 별도 게이트다.

## 2026-09-02 REL902A001 · CLN902A001 최신 배포·문서·저장소 정리

- build 126 배포 소스는 `6b302ea2f9bca3f818c829514af1ee147b83be47`이며, Release archive/export·Apple Distribution 서명·네 번들 `1.0 (126)`·deep/strict codesign·`altool --validate-app` 검증을 완료했다.
- TestFlight Delivery UUID는 `8e66a688-a922-4f76-b761-4da7b3faadb1`이고 App Store Connect API에서 build 126 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`를 확인했다. `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 연결되어 그룹 빌드 87개와 내부 테스터 1명을 API readback했다.
- App Store Connect 그룹 빌드·테스터 화면은 Chrome과 in-app Browser가 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 남은 게이트다. Apple Watch 현장 수신과 Paid Apps Agreement·IAP·Sandbox 구매/복원도 기존 미완료 게이트로 유지한다.
- CLN902A001에서 종료된 구형 iOS Simulator 5대의 device data를 삭제했다. iOS/watchOS 26.5 runtime은 보존했다. 이후 다른 작업이 새 iPad Simulator `2CD5BB05-7C63-4D44-A0B3-170F83F62210`를 부팅해 실행한 XCTest는 중단하지 않았다.
- `/private/tmp`에서 문서 증적·현재 TestFlight archive·활성 카메라 로그를 제외한 소유 가능한 이전 임시 산출물 2,387개 약 27.92G를 정리했고, root 소유 `FTABHarvest` 1개는 보존했다. `XCTestDevices`·Xcode `DerivedData`는 0B, Xcode `Archives` 1.4G는 보존했다.
- 정리 readback은 `/private/tmp` 50G, 데이터 볼륨 여유 61G, 사용자 휴지통 0개다. `.codex`, 소스, 현재 실행 중인 WBS33 XCTest 산출물, REL902A001 release 증적, 활성 카메라 로그는 삭제하지 않았다.

## 2026-09-02 REL902A002 GTR 데이터 신뢰도·추론 통합

- 활동·수면·장소·이동·센서 판정에 `ActivityDataProvenance`를 연결해 원본 관측, 보조 데이터, 예상 데이터, 사용자 교정을 구분한다. 원본 센서와 확정 기록은 보존하고 화면·정본 이벤트에는 provenance marker를 함께 기록한다.
- 수면 추론은 iPhone 원본의 화면 꺼짐·무사용·이동 없음·충전/자택/야간 보조 조건을 모두 만족하고 5분 지속될 때만 자동 예상 기록을 만든다. 기존 자동 잠금과 사용자 확인 교정은 별도 상태로 유지한다.
- 장소·활동 분류와 GPS 공백 경로는 근거·confidence·model version을 유지하며, `Review`·`Schedule`·`MapHome`은 실제/보조/예상/미확인 신뢰도 라벨과 이동수단을 동일하게 투영한다. 원본 GPS와 예상 경로를 섞어 덮어쓰지 않는다.
- 앱·iOS Widget·Watch 앱·Watch Widget의 배포 build number를 `1.0 (127)`로 올렸다. 배포 소스 커밋은 `311b5832cc9819e91f16c79af2970eb7a6dbc51b`이며 `main`·`origin/main`·원격 main이 일치한다.

### 검증

- `TaptionActivityEngine` package 12/12, `TaptionRouteEngine` package 17/17 통과
- `TaptionPlan` 전체 XCTest 900/900 통과: iPad Pro (12.9-inch) (6th generation), iOS 26.5, `/tmp/GTR902A001-full-tests/Logs/Test/Test-TaptionPlan-2026.09.02_22-52-06-+0900.xcresult`
- 앱 target generic iOS Debug build 통과: `/private/tmp/GTR902A001-app-target-auto/Build/Products/Debug-iphonesimulator/TaptionPlan.app`
- Release archive/export 통과: `/private/tmp/REL902A002-release-v2/TaptionPlan-1.0-127.xcarchive`, `/private/tmp/REL902A002-release-v2/Export/TaptionPlan.ipa`; IPA SHA-256 `05f179337b4bdaa5c7dcd887adc1f5246ccd27de00d0d394210829f2c99c8aa0`
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (127)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign 및 `altool --validate-app` 통과
- TestFlight 업로드 성공: Delivery UUID `3297b1a2-fde1-40b3-b219-b99f13cf4c1e`; App Store Connect API 처리 상태 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`
- `TP Taption Plan 내부 테스트`(ID `b4857e5e-d1ff-4bc2-b9ad-a69bcd4603fd`)에 build 127 연결 성공. 그룹 빌드 API에서 build 127과 전체 88개 빌드, 테스터 API에서 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- App Store Connect 그룹 빌드·테스터 실제 화면은 Chrome과 in-app Browser 모두 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 UI readback만 남은 게이트다.

## 2026-09-03 TF26PUSH01 build 128 TestFlight·기기 readback

- build number를 `1.0 (128)`로 올린 배포 소스 `84448b8aa8fc7b9de35b2903561a90095c2bee62`를 `main`에 커밋·푸시했다.
- `TaptionPlanCore` 40건, `TaptionActivityEngine` 12건, `TaptionRouteEngine` 17건, `TaptionPlanEngine` 1건 package 테스트가 모두 통과했다.
- Release archive/export 성공: `/private/tmp/TF26PUSH01-release-r2/TaptionPlan-1.0-128.xcarchive`, `/private/tmp/TF26PUSH01-release-r2/Export/TaptionPlan.ipa`; IPA SHA-256 `b6532fc4be01c52a03fe1ef85f60b3bdb5156f77901cdd7483812834db9154e6`.
- 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (128)`, Apple Distribution 서명·Production iCloud·TestFlight entitlement·deep/strict codesign·`altool --validate-app` 통과.
- TestFlight 업로드 성공: Delivery UUID `3ce79d87-b2cd-429e-b988-816d0b9af84a`; App Store Connect API에서 build 128 `VALID`·`expired=false`를 확인했다.
- `TP Taption Plan 내부 테스트`에 build 128 연결 성공. 그룹 빌드 API에서 전체 89개와 build 128, 내부 테스터 API에서 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- iPhone 14 Pro(`C44AF739-127D-572D-AD83-417C7E879045`) TestFlight 화면에서 Taption Plan 업데이트를 수행했고, `devicectl`로 `com.taption.plan` `1.0 (128)` 설치와 PID `26948` launch를 readback했다.
- iPad Pro(`4CEC6BE9-E528-52A1-AB94-654A6CDA7E5E`)는 현재 `1.0 (125)`이며 TestFlight 앱이 설치돼 있지 않다. beta IPA의 CoreDevice 직접 설치는 `0xe800801f Attempted to install a Beta profile without the proper entitlement`로 거부되어 TestFlight 앱을 통한 iPad 128 다운로드·설치·launch는 미완료다.
- App Store Connect 그룹 빌드·테스터 실제 화면은 로그인 화면으로 열려 자격 증명을 입력하지 않았으므로 UI readback은 미완료다.

## 2026-09-03 SLP903TF02 수면 연결 복구·TestFlight build 129

- 오늘 iCloud 월간·raw 센서 백업은 정상 갱신됐지만 Watch 건강 스냅샷이 `health_enabled=false`로 처리되어 HealthKit 수면 조회가 생략된 것이 누락 원인이었다.
- 오늘 수면 기록이 없고 건강 연동이 꺼진 경우 일정 화면에 원인 안내와 명시적 `수면 연결` 버튼을 표시한다. 버튼은 기존 HealthKit 권한 요청·전체 이력 동기화 경로를 사용하며 백그라운드에서 권한을 임의 활성화하지 않는다.
- 배포 소스 `3544ff8baf551cbe0b0817029e5ad5962048a6fa`, 전체 XCTest 901/901, generic iOS Debug build, Release archive/export, 네 번들 `1.0 (129)`, Production iCloud/TestFlight entitlement, deep/strict codesign과 `altool --validate-app`을 확인했다.
- archive `/private/tmp/SLP903TF02-release/TaptionPlan-1.0-129.xcarchive`, IPA `/private/tmp/SLP903TF02-release/Export/TaptionPlan.ipa`, SHA-256 `3acc55045b44c3bbc94e6172edf43f372ab9efba467b347e65b8aec2d546c723`이다.
- TestFlight Delivery UUID `411a22f3-430a-48fb-bde7-03269ca710e6`은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 90개 중 build 129와 내부 테스터 1명(`INSTALLED`)을 readback했다.
- 실제 iPhone에서 `수면 연결` 탭·HealthKit 수면 권한 승인·오늘 기록 재조회와 build 129 설치·launch는 사용자가 돌아온 뒤 확인할 별도 물리 게이트다.

## 2026-09-03 SID903A001 날짜 전환 사이드바 분류 유지

- 날짜 변경 시 지도 일자 상태 초기화가 사이드바 레일을 하루 전체 `미확인`으로 먼저 덮어쓰는 원인을 확인했다.
- 경로 상태를 초기화할 때 선택한 날짜의 저장 actual·travel을 즉시 다시 투영해 대분류를 유지하도록 수정했다.
- 서로 다른 날짜의 `업무`·`수업` 분류가 섞이거나 미확인으로 소실되지 않는 집중 XCTest와 Debug 테스트 빌드를 통과했다: `/private/tmp/SID903A001-focused-r2.xcresult`.

## 2026-09-03 TF903B013X TestFlight build 130

- 날짜 전환 사이드바 대분류 유지 수정이 포함된 배포 소스 `1829efb1d02c7e81724787e5c787a9d4fff260a1`를 main에 푸시했다.
- 전체 XCTest 902/902, 실패·스킵 0을 통과했다: `/private/tmp/TF903B013X-full.xcresult`.
- Release archive/export와 네 번들 `1.0 (130)`, Production iCloud/TestFlight entitlement, deep/strict codesign, `altool --validate-app`을 확인했다.
- archive `/private/tmp/TF903B013X-release/TaptionPlan-1.0-130.xcarchive`, IPA `/private/tmp/TF903B013X-release/Export/TaptionPlan.ipa`, SHA-256 `0904b72f68a00f32bd7cd29b48c027acfb4764c684d3696265b1fb1035218fa8`이다.
- Delivery UUID `064f2803-95d1-458b-96bc-819b087c13c9`은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. 내부 그룹 연결 후 그룹 build 91개 중 build 130과 내부 테스터 1명(`INSTALLED`)을 readback했다.

## 2026-09-03 REL903TF01 TestFlight build 131

- Apple Watch 자동 가져오기·가속도 설정을 Watch 앱 행 바로 아래로 이동하고, 이동이 아닌 졸라맨 동작은 정지 프레임으로 고정했다.
- 기능 소스 `4c5d9aaf76ef558ec3302f2763bb27562eac45aa`, 배포 소스 `cceb9f655c76b4e5981891ed7f80c89f03b6a2cc`를 `main`에 푸시했다. 비이동 동작 회귀 XCTest와 Debug 테스트 빌드가 통과했다.
- Release archive/export 성공: `/private/tmp/taption-rel903-build131/TaptionPlan-1.0-131.xcarchive`, `/private/tmp/taption-rel903-build131/Export/TaptionPlan.ipa`; 네 번들 모두 `1.0 (131)`, deep/strict codesign과 `altool --validate-app` 통과, IPA SHA-256 `4435667dba069fda3706217b5c6af8947cef75eb72689525bc2fd75dd603f6f8`.
- Delivery/build UUID `805169b0-e3d9-41b2-883d-475504a3884d`는 API에서 `VALID`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 92개 중 build 131과 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 131 실기기 설치·launch와 실제 Watch 설정·비이동 정지 화면 확인은 별도 물리 게이트다.

## 2026-09-04 LOG904TF01 진단 로그·TestFlight build 132

- 잠긴 걷기 판정보다 최신 유효 지하철 노선을 우선하도록 수정하고, 이동 판정에는 지하철 노선/모드 불일치·잠금 수, 권한 흐름에는 안내 사유·HealthKit 요청/완료/실패를 진단 로그로 남긴다. 기존 예상경로 생성 이벤트와 `health_refresh_completed`의 수면 세션 수도 함께 확인할 수 있다.
- 집중 XCTest 4/4와 Release archive/export, `altool --validate-app`을 통과했다. 배포 소스 `f3425f951d9b05e67be39fcab62847244e77d31f`, 네 번들 `1.0 (132)`, archive `/private/tmp/taption-rel904-build132/TaptionPlan.xcarchive`, IPA `/private/tmp/taption-rel904-build132/Export/TaptionPlan.ipa`, SHA-256 `afc0a852750c0b67e017453a5b9c3aea05cf6b41bb89be211185496ac4de0b5b`다.
- Delivery/build UUID `5d01450c-2c10-4b8f-bcff-8852258fe2f1`은 API에서 `VALID`·`APP_STORE_ELIGIBLE`·`expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 그룹 build 93개 중 build 132와 내부 테스터 1명(`axony99@gmail.com`, `INSTALLED`)을 readback했다.
- build 132 설치·launch 및 지하철·예상경로·수면 iCloud 로그 확인은 대표님 테스트 뒤 진행할 물리 게이트다.

## 2026-09-04 TFB904A133 실행 성능·TestFlight build 133

- 실행마다 30일 파생 데이터를 다시 만들고 불완전 day DB 마이그레이션과 원시 센서 백업을 반복하던 경로를 제거·복구형으로 바꾼 기능 커밋은 `8d041e9284d8393cbbf1157cf2b795c1cb6b51cf`, build 133 배포 소스는 `3930b808c86f20b003e474c56846252156303b41`이다.
- 관련 XCTest 4/4와 generic iOS Simulator Debug build가 통과했다. Release archive/export 및 `altool --validate-app`도 통과했고, 앱·iOS Widget·Watch 앱·Watch Widget 모두 `1.0 (133)`, Apple Distribution 서명, `beta-reports-active=true`, `get-task-allow=false`다.
- archive `/private/tmp/TFB904A133-release/TaptionPlan-1.0-133.xcarchive`, IPA `/private/tmp/TFB904A133-release/Export/TaptionPlan.ipa`, SHA-256 `422bcb43a8822b7eac2ff7935471acecddd5a46c2ade6a506ccf6cebdda92f4a`다.
- Delivery/build UUID `bc2b0f81-83f2-4001-80f2-19707a1b1fcc`는 `BUILD-STATUS: VALID`, `IMPORT-STATUS: VALID`, `APP_STORE_ELIGIBLE`, `expired=false`다. `TP Taption Plan 내부 테스트` 연결 후 API에서 그룹 build 94개 중 build 133과 내부 테스터 1명(`INSTALLED`)을 readback했다.
- Chrome 그룹 빌드 화면에서 `1.0 (133) · 테스트 중 · iOS`, 테스터 화면에서 내부 테스터 1명과 그룹 전체 94개 빌드를 확인했다. 테스터 설치 표시는 기존 `1.0 (132)`이므로 build 133 TestFlight 설치·launch·실제 발열은 별도 물리 게이트다.
- 디스크 확보를 위해 재생성 가능한 성능 검증·build 132·build 133 DerivedData 약 3.2G를 영구 삭제했다. build 132/133 archive·IPA와 build 133 XCTest 결과는 보존했다.

## 2026-09-04 REL904A001 센서 위치·수면·경로·지하철 수정 및 TestFlight build 134

- iCloud 로그에서 현재위치 점과 졸라맨의 좌표 소스 분리, iPhone 수면 표본 역순으로 인한 0초 provenance, 8분·6.7km 경로 공백 기준 불일치, 후속 재분석의 중간 신뢰도 지하철 덮어쓰기를 확인하고 수정했다.
- `TaptionActivityEngine` package 12/12, iOS 집중 XCTest 3/3, Debug build가 통과했다. 배포 소스 커밋 `f99d72b93919e8646a6fc7d9908330e524eb6034`를 `main`에 커밋·푸시했다.
- Release archive/export 성공: `/private/tmp/taption-rel904-build134/TaptionPlan.xcarchive`, `/private/tmp/taption-rel904-build134/Export/TaptionPlan.ipa`; 네 번들 `1.0 (134)`, IPA SHA-256 `225ba74b3de11b05e1c4a530d20a21b495b34ca0b22f8af503184b9dabf45851`이다.
- `altool --validate-app` 및 업로드 성공. Delivery UUID `a3581625-8668-4d3a-85c1-240078bc054e`는 App Store Connect API에서 `VALID`, `expired=false`로 readback했다.
- `TP Taption Plan 내부 테스트`에 build 134 연결 후 그룹 빌드 API에서 build 134와 내부 테스터 1명을 readback했다. TestFlight 설치·실행·발열·실제 수면·지하철 화면은 별도 물리 게이트다.
