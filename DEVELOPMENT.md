# 개발 안내

이 문서는 코드 위치와 재사용 가능한 검증 명령만 설명합니다. 요청 상태는 `temp.md`, 실행 증거는 `test.md`에서 요청 ID로 찾고, 현재 코드를 기준으로 작업하세요.

## 프로젝트 경계

| 영역 | 위치 |
| --- | --- |
| 앱 상태·저장 조정 | `TaptionPlan/UX/AppModel.swift` |
| 일자 데이터 값·원본 정렬·fingerprint | `TaptionPlan/Core/PlanDayDataSnapshot.swift` |
| 공통 캐시·입력 예산·UUID 순서 | `Packages/TaptionPlanCore/Sources/TaptionPlanCore/RuntimeEfficiency.swift` |
| 지도 카메라·터치 정책 | `TaptionPlan/UI/MapHomeInteractionPolicy.swift` |
| 지도·시간축·시간표 UI | `TaptionPlan/UI/MapHomeView.swift`, `MapHomeTimeSidebar.swift`, `ScheduleView.swift` |
| SQLite 저장·일자 DB·암호화 백업 | `TaptionPlan/Core/PlanRepository.swift`, `PlanDayDatabase.swift`, `SecurityBackupCore.swift` |
| 센서·HealthKit·Apple 연동 | `TaptionPlan/Core/SensorDataServices.swift`, `HealthKitImportCoordinator.swift`, `HealthKitImportStore.swift`, `AppleIntegrations.swift` |
| 앱과 엔진 연결 | `TaptionPlan/Core/RouteTimelineData.swift`, `TaptionRouteEngineAdapter.swift`, `TaptionActivityEngineAdapter.swift` |
| 공유 엔진 | `Packages/TaptionPlanCore/`, `Packages/TaptionActivityEngine/`, `Packages/TaptionRouteEngine/`, `Packages/TaptionPlanEngine/` |
| Watch·위젯 | `TaptionPlanWatch/`, `TaptionPlanWidget/`, `TaptionPlanWatchWidget/` |
| 회귀 테스트 | `TaptionPlanTests/`, 각 package의 `Tests/` |

앱 전용 프레임워크와 화면은 Swift Package로 옮기지 않습니다. package import 경계 검사는 `bash scripts/check-app-engine-import-boundary.sh`로 확인합니다.

HealthKit의 앱 읽기/import 허용 목록은 `TaptionHealthReadScope`의 8개 항목(운동·수면·심박·걸음·걷기/달리기 거리·자전거 거리·활동 에너지·운동 경로)입니다. 전체 타입 카탈로그는 기존 원본 해석용이며 신규 권한/수집 범위가 아닙니다. 임상·투약·영양·시력·특성·활동 요약 신규 조회는 하지 않고 기존 저장 원본은 보존합니다.

Apple Watch 데이터는 iPhone HealthKit으로 읽습니다. iPhone의 TaptionPlan target은 Watch 앱을 빌드·임베딩하지 않습니다. 기존 Watch 소스와 독립 target은 역사·호환 유지용으로 보존합니다. 앱 활성화 시 건강 연결이 켜져 있으면 즉시 증분 조회하고, 페어링된 Watch가 있으며 아직 건강 연결을 요청하지 않은 경우 사용자 승인을 요청합니다. Watch 앱 설치·실시간 메시지 응답은 조회 조건이 아닙니다. 건강 데이터의 Watch→iPhone 동기화 시점과 읽기 허용 여부는 앱이 강제로 제어하거나 판별할 수 없습니다.

## 보존해야 할 데이터 계약

- `PlanRepository`와 `HealthKitImportStore`는 기존 날짜 없는 snapshot 키 `0000-00-00`을 읽기 위해 `allowsUndatedSnapshots`를 켭니다. 일반 날짜, event, map 검증은 이 예외를 물려받지 않아야 합니다.
- `TaptionPlanCore`의 정본 Codable envelope는 현재 포맷만 읽고 변환을 한 번만 수행합니다. `SecurityBackupCore` 백업 포맷의 legacy read 경로는 별도 계약이므로 포맷 작업 때 구분해 확인하세요.
- 백업 포맷·암호화·체크섬·세대 참조를 바꾸기 전에는 현재 구현과 요청 기록을 확인합니다. 읽기 호환·복원·rollback 기준 없이 기존 백업을 제거하거나 변환하지 않습니다.

- 앱의 복원 메뉴는 `loadLatestBackupPackage(streamRaw: true)`로 V4 raw 암호문을 파일 페이지로 읽고 `PlanStagedRawRestore`의 SQLite cursor를 최대 256행/기본 1MiB씩 소비합니다. 단일 항목은 하드 4MiB 제한입니다. 기존 `.available(payload)`는 호환·진단 경로이며 전체 배열을 반환합니다.
- `RestoreStaging/restore-journal.sqlite`에는 target snapshot digest·세션·필요 저장소·삭제 generation을 기록합니다. 원본 삽입과 `restore_receipts`/`raw_restore_receipts`는 같은 SQLite 트랜잭션입니다. bootstrap은 snapshot 공개 전에 pending 복원을 확정하거나 동일한 신규 원본만 rollback하며, 필요한 저장소가 없으면 journal을 지우지 않습니다. 원본 DB·App Group 경로·facade는 바꾸지 않습니다.
- 과거 snapshot에 연결된 V1–V3 월은 수동 백업에서 보호된 migration journal을 사용해 V4 불변 세대로 변환하며 원본을 유지합니다. raw-only legacy 월, V1–V3 단일 GCM의 strict streaming, 실제 peak memory는 아직 별도 미완료 기준입니다. CloudKit은 Debug Development만 자동 활성화되며, CAS의 본문 재병합·pending 참조·보존 정책은 실제 두 기기 검증과 구분합니다.

## 비용이 큰 경로를 찾을 때

`python3 scripts/runtime-code-inventory.py`는 제품 Swift 파일의 위치·길이·import와 정렬/필터/입력 콜백 위치 수를 출력합니다. 생성물과 캐시는 검색하지 않습니다. 이 수치는 탐색용이며 실제 병목 판정은 측정으로 합니다.

- `TaptionBoundedCache`는 actor 또는 MainActor 소유자가 동기 접근합니다. 조회는 O(1), 용량 초과 삽입 때만 제한된 항목을 검사합니다. `peek`은 recency를 바꾸지 않으며 메모리 압력 시 소유자가 비웁니다.
- `AppModel`의 일자 fingerprint 캐시는 actuals/places/travel 변경 revision에 연결합니다. 캡처한 revision이 현재와 다르면 비동기 결과를 캐시에 넣지 않습니다. `PlanDayLoadCoordinator`에 공급하는 fingerprint는 동일하게 캡처한 source의 값이어야 합니다.
- 일자 DB는 원본 digest를 검증한 materialized 값을 한 번 읽고, source가 다르면 그 값의 raw로 다시 projection합니다. stale preview는 별도 읽기 계약을 유지합니다. 삭제 generation·취소·강제 raw 갱신을 우회하지 않습니다.
- `TaptionLatestValueProjection`과 `TaptionInputFrameGate`가 공통 입력 정책입니다. 동일 상태로 갱신 예산을 소비하지 않고, 종료 이벤트는 최종값을 즉시 반영합니다. UIKit/MapKit 제스처와 표시 좌표는 앱에 남깁니다.
- Release에서 패키지 경계를 넘는 제네릭 캐시가 특수화되도록 작은 조회 함수는 `@inlinable`입니다. Debug 측정만으로 성능 개선을 판단하지 않습니다. 공통 UUID 비교는 기존 대문자 UUID 문자열 순서와 같아 fingerprint 호환성을 유지합니다.

## 검증 명령

집 성장 그림은 `HomeEvolution001...366` 자산명과 기존 저장 레벨을 유지합니다. `scripts/home_evolution_artwork_manifest.json`이 승인한 122종 × 3레벨 원본 해시와 매핑을 기록합니다. `python3 scripts/generate_home_evolution_artwork.py --check`로 현재 자산을 대조하고, `--write`는 manifest에 지정된 디자인 원본을 기존 자산에 반영합니다. 512px 출력 원본의 내부 도형/viewBox를 유지하며 앱 벡터 기준 크기는 128pt, vector representation은 보존합니다. 성장·보상 회귀와 실제 번들 그림의 48pt 렌더 검사는 `MapHomeGrowthPolicyTests`에 있습니다.

현재 scheme과 target은 프로젝트에서 확인합니다.

```sh
xcodebuild -list -project TaptionPlan.xcodeproj
```

바꾼 공유 package만 테스트합니다. 예를 들어 저장 계약 변경은 다음 명령을 사용합니다.

```sh
swift test --package-path Packages/TaptionPlanCore
```

앱 Debug 빌드는 generic iOS destination으로 실행합니다. 아래 플래그는 현재 검증 기록에 사용한 Swift macro sandbox 우회입니다. 프로젝트의 기존 DerivedData를 재사용하고 실패하면 첫 관련 오류만 확인합니다.

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/ArchiveDD -skipPackagePluginValidation \
  COMPILER_INDEX_STORE_ENABLE=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

Watch 코드를 바꾼 경우 Watch scheme도 별도로 빌드합니다.

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlanWatch \
  -configuration Debug -destination 'generic/platform=watchOS' \
  -derivedDataPath build/ArchiveDD -skipPackagePluginValidation \
  COMPILER_INDEX_STORE_ENABLE=NO \
  OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
```

빌드 번호는 project setting만 바꾸면 충분하지 않습니다. 앱·iPhone 위젯·Watch 앱·Watch 위젯 네 `Info.plist`의 고정 `CFBundleVersion`도 같은 값이어야 합니다. 현재 iPhone 배포에는 앱·iPhone Widget 두 제품만 포함하며 Watch 디렉터리가 없어야 합니다. 독립 Watch target의 원본 번호도 일치시키되 Watch 제품을 배포에 추가하지 않습니다. 설치·TestFlight 전 최종 `.app`/`.appex`의 `CFBundleIdentifier`와 `CFBundleVersion`을 읽어 확인하세요. `CURRENT_PROJECT_VERSION`과 산출물 번호가 일치한다고 가정하지 않습니다.

실기기 설치본 버전은 `xcrun devicectl device info apps --device "$DEVICE_ID" --bundle-id com.taption.plan`으로 읽습니다. 설치 및 앱 실행만으로 권한, 저장, 센서, 계정 기능을 통과 처리하지 않습니다.

앱 테스트는 현재 사용 가능한 Simulator UDID를 먼저 조회하고 관련 테스트만 선택합니다. 매 실행마다 요청 ID 아래 새 result bundle 경로를 사용합니다.

```sh
xcrun simctl list devices available
mkdir -p "build/validation/$TASK_ID"
xcodebuild test -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -derivedDataPath build/ArchiveDD \
  -resultBundlePath "build/validation/$TASK_ID/app-tests.xcresult" \
  -only-testing:TaptionPlanTests/$TEST_CLASS
```

`TASK_ID`는 요청의 10자리 ID, `SIMULATOR_UDID`는 위 목록의 값, `TEST_CLASS`는 변경에 맞는 테스트 클래스로 설정합니다. 전체 앱 테스트를 실행했다면 xcresult의 실제 테스트 수·실패·건너뜀을 확인합니다. 시뮬레이터 결과는 설치·실기기 기능 검증이나 TestFlight 결과를 뜻하지 않습니다.
