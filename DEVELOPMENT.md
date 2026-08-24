# Taption Plan 개발 문서

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
