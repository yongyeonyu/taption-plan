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

## 2026-08-26 경로·분류 잠금·NLE 반응성 통합

- `TaptionPlanCore`는 일자 단위 SQLite 저장소와 generation 기반 NLE 입력 예산을 제공한다. 고빈도 제스처 입력은 최대 60Hz로 제한하고 제스처 종료 최종값은 즉시 반영한다.
- `TaptionActivityEngine`은 상세·대분류 taxonomy와 센서 근거 분류를 담당하며, 자동 생성된 수면·이동·HealthKit·위치·지하철 분류와 `TravelSegment`는 저장 후 다시 분류되지 않는다. 사용자 편집만 저장된 결과를 덮어쓰며 원본 센서 자료는 보존한다.
- `TaptionRouteEngine`은 동일 시각 중복 우선순위, 2D constant-velocity Kalman 필터, 정지 드리프트 억제, 정확도 경계, 불가능한 점프·15분 공백 세그먼트 분리와 RDP 표시 축약을 담당한다.
- 앱 시작은 로컬 스냅샷과 일자 데이터를 먼저 hydrate한 뒤 홈을 연다. 사이드바·경로·지도 파생값은 캐시하고 드래그 중 전체 일자 재계산을 피한다.
- 지도 현재·과거 위치는 native annotation 졸라맨으로 통일해 장소 아이콘보다 앞에 표시한다. 추적 중 선택 시각 위치를 중앙에 유지하고, 지도 이동 시 추적을 해제하며 핀치 줌·사이드바 핸들의 터치 영역을 확장했다.
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
- `TP Taption Plan 내부 테스트` 그룹 연결 및 그룹 builds 노출 확인은 외부 접근 변경 승인 후 남은 게이트다.
