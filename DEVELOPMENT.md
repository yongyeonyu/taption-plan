# 개발 안내

이 문서는 코드 위치와 재사용 가능한 검증 명령만 설명합니다. 요청 상태는 `temp.md`, 실행 증거는 `test.md`에서 요청 ID로 찾고, 현재 코드를 기준으로 작업하세요.

## 프로젝트 경계

| 영역 | 위치 |
| --- | --- |
| 앱 상태·저장 조정 | `TaptionPlan/UX/AppModel.swift` |
| 지도·시간축·시간표 UI | `TaptionPlan/UI/MapHomeView.swift`, `MapHomeTimeSidebar.swift`, `ScheduleView.swift` |
| SQLite 저장·일자 DB·암호화 백업 | `TaptionPlan/Core/PlanRepository.swift`, `PlanDayDatabase.swift`, `SecurityBackupCore.swift` |
| 센서·HealthKit·Apple 연동 | `TaptionPlan/Core/SensorDataServices.swift`, `HealthKitImportCoordinator.swift`, `HealthKitImportStore.swift`, `AppleIntegrations.swift` |
| 앱과 엔진 연결 | `TaptionPlan/Core/RouteTimelineData.swift`, `TaptionRouteEngineAdapter.swift`, `TaptionActivityEngineAdapter.swift` |
| 공유 엔진 | `Packages/TaptionPlanCore/`, `Packages/TaptionActivityEngine/`, `Packages/TaptionRouteEngine/`, `Packages/TaptionPlanEngine/` |
| Watch·위젯 | `TaptionPlanWatch/`, `TaptionPlanWidget/`, `TaptionPlanWatchWidget/` |
| 회귀 테스트 | `TaptionPlanTests/`, 각 package의 `Tests/` |

앱 전용 프레임워크와 화면은 Swift Package로 옮기지 않습니다. package import 경계 검사는 `bash scripts/check-app-engine-import-boundary.sh`로 확인합니다.

## 보존해야 할 데이터 계약

- `PlanRepository`와 `HealthKitImportStore`는 기존 날짜 없는 snapshot 키 `0000-00-00`을 읽기 위해 `allowsUndatedSnapshots`를 켭니다. 일반 날짜, event, map 검증은 이 예외를 물려받지 않아야 합니다.
- `TaptionPlanCore`의 정본 Codable envelope는 현재 포맷만 읽고 변환을 한 번만 수행합니다. `SecurityBackupCore` 백업 포맷의 legacy read 경로는 별도 계약이므로 포맷 작업 때 구분해 확인하세요.
- 백업 포맷·암호화·체크섬·세대 참조를 바꾸기 전에는 현재 구현과 요청 기록을 확인합니다. 읽기 호환·복원·rollback 기준 없이 기존 백업을 제거하거나 변환하지 않습니다.

## 검증 명령

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

빌드 번호는 project setting만 바꾸면 충분하지 않습니다. 앱·iPhone 위젯·Watch 앱·Watch 위젯 네 `Info.plist`의 고정 `CFBundleVersion`도 같은 값이어야 합니다. 설치·TestFlight 전 최종 `.app`/`.appex`의 `CFBundleIdentifier`와 `CFBundleVersion`을 읽어 확인하세요. `CURRENT_PROJECT_VERSION`과 산출물 번호가 일치한다고 가정하지 않습니다.

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
