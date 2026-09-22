# Kiro AI 개발 인수인계 프롬프트

이 문서 전체를 Kiro AI에 전달하거나, 저장소에서 이 문서를 읽고 아래 범위를 이어서 개발하도록 지시하세요. 기준일은 2026-09-23이며 실제 소스와 새 실행 결과를 우선합니다. 인수인계 시 검증한 구현 기준 커밋은 `a8e3d5c`입니다.

## 역할과 작업 원칙

Taption Plan의 기존 개발을 이어서 진행하세요. 대표님께 한국어 존댓말로 결과·검증·남은 제한을 간결하게 보고하세요.

- 작업 폴더: `/Users/u_mo_c/Documents/taption plan`; 저장소: `https://github.com/yongyeonyu/taption-plan.git`; 브랜치: `main`.
- 먼저 `AGENTS.md`, 이 문서, `temp.md`, `test.md`와 `git status --short --branch`를 확인하세요. 허락 없이 임시 브랜치나 worktree를 만들지 마세요.
- 새 요구사항은 영문·숫자 10자리 ID로 `temp.md`에 원인·해결·검증 기준을 적고 대기합니다. 명시적으로 실행을 요청한 범위만 수행하고 이미 승인한 범위를 다시 묻지 마세요. 이 인수인계로 이어갈 범위는 아래 우선순위의 기존 코드 검토·확정 결함 수정·미완료 검증입니다.
- 완료 증거가 있는 항목만 `temp.md`에서 제거해 `test.md`에 짧게 남기세요. 큰 로그·xcresult는 Git에서 제외된 `build/validation/<ID>/`에 저장하세요. 중복 계획서·진행 보고서를 추가로 만들지 마세요.
- 기존 사용자 변경·원본 센서·백업·PIN/키·다른 프로젝트 작업을 보존하세요. 데이터 삭제나 앱 제거로 검증 환경을 초기화하지 마세요.
- 단순 작업은 직접 처리하세요. 독립 작업을 병렬 위임할 때만 Luna를 사용하며, 해당 모델을 선택할 수 없으면 직접 진행하세요. SOL·고속 모드는 사용하지 마세요. 같은 파일을 여러 작업이 동시에 수정하면 안 됩니다.
- 기능 변경 뒤 관련 단위 테스트와 Debug 빌드를 실행하세요. 설치·실제 입력·저장·재열기·기기 간 전송은 각각 별도 증거가 필요합니다. 통과한 테스트는 변경이나 새 위험이 없으면 반복하지 마세요.

## 현재 소스와 제품 구조

SwiftUI 기반 iPhone/iPad 앱으로 Map Home, 시간표·계획·회고, 자동 센서/HealthKit 기록, 지도 경로·재생, iCloud 암호화 백업, Apple Watch 및 위젯을 포함합니다.

| 위치 | 책임 |
| --- | --- |
| `TaptionPlan/UX/AppModel.swift` | 앱 상태, 로딩·편집·저장·백업 복원 조정 |
| `TaptionPlan/UI/MapHomeView.swift`, `MapHomeTimeSidebar.swift`, `ScheduleView.swift` | 지도·시간축·시간표 및 화면 갱신 |
| `TaptionPlan/Core/PlanRepository.swift`, `PlanDayDatabase.swift` | SQLite 정본, 일자 projection 및 migration |
| `TaptionPlan/Core/SecurityBackupCore.swift` | 암호화 백업, 원본 generation, 복원·취소·rollback |
| `TaptionPlan/Core/SensorDataServices.swift`, `SensorFusion.swift`, `AppleIntegrations.swift` | 원본 수집·저장·분류 및 Apple 연동 |
| `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `HealthKitImportStore.swift` | HealthKit 가져오기·삭제·checkpoint |
| `TaptionPlan/Core/RouteTimelineData.swift`, `TaptionRouteEngineAdapter.swift`, `TaptionActivityEngineAdapter.swift` | 앱 모델과 엔진 연결, 경로·분류 파생값 |
| `TaptionPlanWatch/`, `TaptionPlan/Core/WatchSyncModels.swift`, `WatchDayDatabase.swift`, `WatchAmbientSummaryAccumulator.swift` | Watch 운동·센서 lifecycle, durable outbox·ACK·삭제 |
| `TaptionPlanWidget/`, `TaptionPlanWatchWidget/` | 위젯·Live Activity·Watch complication |
| `Packages/TaptionPlanCore` | SQLite 저장·무결성·일자 키·원본 paging 계약 |
| `Packages/TaptionActivityEngine`, `Packages/TaptionRouteEngine` | 분류·경로·시간 인덱스·재생 계산 |
| `Packages/TaptionPlanEngine` | 앱이 사용하는 공개 facade |
| `TaptionPlanTests/`, `Packages/*/Tests/` | 앱 통합·저장·동시성 및 패키지 회귀 |

인수인계 직전 변경은 watchdog/CPU 경로의 반복 스캔 제거, 취소·generation 검사, 저장 실패 시 편집 차단, 백업 무결성과 rollback, Watch outbox/purge, HealthKit 동기화, 경로·분류 인덱스 및 회귀 테스트 보강을 포함합니다. 이미 구현된 부분을 추측으로 다시 작성하지 마세요. `scripts/check-app-engine-import-boundary.sh`는 앱의 `TaptionRouteEngine` 직접 import를 검사합니다.

저장·성능 경계는 `AGENTS.md`를 지키세요. 앱 UI·MapKit·ActivityKit을 Swift Package에 넣지 않습니다. 자동 기록은 원본과 판정 근거를 보존하고 사용자 편집 대상인 수동 계획과 구분합니다. SQLite payload는 LZFSE·체크섬·바이트 수를 유지하며, 구버전 백업 읽기 호환성을 임의로 제거하지 않습니다. 입력 callback에서 전체 계산을 하지 않고 화면 갱신을 최대 60Hz로 합치며 오래된 projection은 폐기합니다.

HealthKit 동기화 checkpoint와 앱 전체 계획 snapshot은 과거부터 날짜 없는 키 `0000-00-00`을 사용합니다. `HealthKitImportStore`와 `SQLitePlanRepository`가 `TaptionPlanDayStore(allowsUndatedSnapshots: true)`를 명시해 기존 데이터·anchor·revision을 읽고 갱신합니다. 일반 DayStore 기본값, event·map 및 V3의 유효 날짜 검사는 유지하세요. 이 호환 경계를 없애면 앱 저장과 HealthKit 동기화가 `invalidDay`로 실패합니다.

## 실제 확인한 빌드 환경

| 항목 | 2026-09-23 로컬 값 |
| --- | --- |
| Mac | Apple Silicon arm64, macOS 26.6.2 (25G83) |
| Xcode | 27.0 (27A266a), `/Applications/Xcode.app/Contents/Developer` |
| Swift | 컴파일러 6.4; 프로젝트 언어 모드·Swift tools 6.0 |
| 최소 OS | iOS/iPadOS 18.0, watchOS 11.0; 패키지 macOS 13.0 |
| 프로젝트·스킴 | `TaptionPlan.xcodeproj`; `TaptionPlan`, `TaptionPlanWatch` |
| 번들 버전 | 앱·iOS 위젯·Watch 앱·Watch 위젯 모두 `1.0 (149)` |
| 서명 | Automatic, Team `4FWG8XXYM7` |
| Bundle ID | `com.taption.plan`, `.widget`, `.watchkitapp`, `.watchkitapp.widget` |
| 공유 컨테이너 | App Group `group.com.taption.plan`; iCloud `iCloud.com.taption.plan` |
| 외부 의존성 | SwiftPM MapLibre, manifest `6.29.0..<7.0.0`; 기존 로컬 resolve는 6.29.0 |
| 테스트 runtime | 설치된 iOS Simulator 26.5, watchOS Simulator 26.5 |

Xcode의 개발자 도구와 Simulator runtime을 먼저 확인하세요. npm·CocoaPods·별도 서버는 필요하지 않습니다. 외부 Swift Package 최초 resolve에는 네트워크가 필요합니다. `Package.resolved`는 현재 Git에서 제외되어 있으므로 다른 Mac의 해결 버전을 확인하세요.

```sh
cd '/Users/u_mo_c/Documents/taption plan'
git status --short --branch
xcode-select -p
xcodebuild -version
swift --version
xcrun simctl list devices available
df -h .
```

현재 Mac은 다른 Taption 프로젝트와 Xcode 빌드 잠금을 공유합니다. 다음을 **동일한 zsh 세션**에서 실행하고 마지막에 해제하세요. 소유자가 살아 있는 잠금을 강제로 지우지 마세요. 다른 Mac에서는 이 외부 스크립트가 없을 수 있으므로 그 Mac의 빌드 작업을 먼저 확인하세요.

```sh
source '/Users/u_mo_c/Documents/taption studio/ios/Scripts/build_lock.sh'
export TAPTION_BUILD_LOCK_TIMEOUT=300
taption_build_lock_acquire || exit 1
# 아래에서 필요한 빌드·테스트를 실행
taption_build_lock_release
```

조회 당시 여유 디스크는 약 9.6GiB였습니다. 빌드 전에 재확인하고 기존의 사용 가능한 DerivedData를 활용하세요. 일반 작업마다 전체 캐시·휴지통을 삭제하지 마세요. 로컬 `.codex/`와 `.workbuddy-ai/`는 개인 도구 설정·과거 메모로 보존하되 Git에서 제외했으며 빌드 의존성이 아닙니다.

## 재현 명령

아래 명령은 저장소 루트에서 실행합니다. 작업 ID는 새 영문·숫자 10자리 값으로 지정하고, 테스트 Simulator ID는 방금 조회한 목록에서 고르세요. 기존 결과 bundle과 같은 경로로 재실행하지 마세요.

패키지와 앱 import 경계:

```sh
for pkg in TaptionPlanCore TaptionActivityEngine TaptionRouteEngine TaptionPlanEngine; do
  swift test --package-path "Packages/$pkg" || exit 1
done
bash scripts/check-app-engine-import-boundary.sh
```

iOS Simulator Debug 빌드:

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/KiroDerivedData CODE_SIGNING_ALLOWED=NO
```

Watch Simulator Debug 빌드:

```sh
xcodebuild build -project TaptionPlan.xcodeproj -scheme TaptionPlanWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath build/KiroDerivedData CODE_SIGNING_ALLOWED=NO
```

앱 XCTest의 아래 UDID는 현재 Mac의 `TRP0922A01 Validation iPhone`입니다. 다른 Mac에서는 실제 목록의 값으로 바꾸세요. `TaptionPlanWatch`에는 독립 Testable이 없으며 Watch 공용 로직 회귀는 앱 XCTest와 패키지 테스트에 포함됩니다.

```sh
KIRO_TASK_ID=KIRORUN001
KIRO_SIMULATOR_ID=09E0872A-C2A8-4E42-B4A0-89F73E1BBA98
mkdir -p "build/validation/$KIRO_TASK_ID"
xcodebuild test -project TaptionPlan.xcodeproj -scheme TaptionPlan \
  -configuration Debug -destination "platform=iOS Simulator,id=$KIRO_SIMULATOR_ID" \
  -derivedDataPath build/KiroDerivedData \
  -resultBundlePath "build/validation/$KIRO_TASK_ID/app-tests.xcresult" \
  -parallel-testing-enabled NO -collect-test-diagnostics never \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 120 \
  -maximum-test-execution-time-allowance 180 CODE_SIGNING_ALLOWED=NO
```

관련 테스트만 실행할 때 `-only-testing:TaptionPlanTests/<TestClass>`를 추가하세요. `CODE_SIGNING_ALLOWED=NO` 산출물은 실기기에 설치할 수 없습니다. Simulator의 HealthKit/App Group 경고와 기존 StoreKit 스킵은 실제 기기 권한·구매 검증 성공을 뜻하지 않습니다. 과거 전체 실행에서 Xcode test worker가 종료 집계 중 멈춘 적이 있으므로 xcresult의 실제 테스트 수·실패·스킵을 읽고, 테스트 시작 전/집계 중 고착을 PASS로 기록하지 마세요.

실기기는 `xcrun devicectl list devices`로 대상 UDID를 확인하고 해당 기기를 destination으로 지정한 서명 빌드를 사용하세요. generic device 빌드의 profile에는 대상 UDID가 없어 설치가 `0xe8008012`로 실패한 사례가 있습니다. Xcode 계정/인증서와 HealthKit·App Groups·iCloud/CloudKit·WeatherKit·Family Controls·Wi-Fi entitlement를 현재 설정과 대조하세요. 계정·키·암호를 프롬프트나 Git에 넣지 마세요.

## 이어갈 우선순위와 남은 제한

정확한 요청 ID·원인·해결·완료 기준은 `temp.md`가 기준입니다.

1. 저장/복원, Watch/HealthKit, 분류·경로·앱 통합 경계를 현재 소스로 검토하고 재현되는 결함만 작게 수정·회귀 검증하세요. 열린 수동 감사 항목을 전체 테스트 통과만으로 닫지 마세요.
2. 실기기에서 9/9 장시간 지도 재생 CPU workload와 9/20 background raw backup file-lock workload를 확인하고 새 OS report·앱 UUID·dSYM을 대조하세요. 짧은 생존 확인은 장시간 재현을 대체하지 않습니다.
3. paired Watch의 tunnel이 살아나면 강제 종료 후 실제 outbox/spool 재전송, iPhone 영구 저장 ACK/receipt, purge 및 HealthKit 삭제를 검증하세요. 마지막 관측은 paired이지만 tunnel disconnected/timeout이었습니다.
4. WeatherKit capability와 서명 entitlement는 확인된 상태입니다. 실기기 provider 응답 및 과거 HTTP 401 해소는 아직 증거가 없습니다. 현재 인증 실패를 6시간 억제하고 Open-Meteo로 fallback하므로 실제 사용 provider를 확인하세요.
5. 사용자 PIN을 기기에서 입력하는 실제 iCloud snapshot/raw 백업·복원, 날짜 왕복·재열기, iPad pinch/VoiceOver, 외부 캘린더 계정 변경은 별도 기기 검증입니다.
6. 대용량 복원·migration의 메모리 상한은 설계 선택이 남아 있습니다. 기존 V3 day payload 유지+사전 cap 초과 시 중단 또는 V4 readings 분리 중 선택을 쉬운 객관식으로 받으세요. raw 복원 v3 chunk 포맷·SQLite staging·recovery journal, 부분 복원 정책, 다중 기기 CloudKit CAS, generation 보존 정책, App Group ID 주입도 별도 선택 대상입니다. 이 결정을 받기 전에 저장 스키마·기존 백업을 바꾸지 마세요.

현재 checkout은 배포된 TestFlight 149 이후의 많은 수정도 포함하지만 버전 번호는 여전히 149입니다. 마지막 기록상 2026-09-13의 TestFlight 149는 처리·내부 그룹 노출까지 완료했고 이후 소스 변경을 새 TestFlight로 업로드한 것은 아닙니다. 이 날짜의 ASC 상태는 새로 조회하지 않았습니다. Debug 149 설치와 배포 149를 같은 코드로 간주하지 마세요. 배포 요청이 오면 네 번들 빌드 번호를 함께 올리고 archive·서명·업로드·처리 후 `TP Taption Plan 내부 테스트`에 연결해 그룹 화면의 빌드·테스터 노출까지 확인하세요. 실제 TestFlight 설치·동작은 다시 별도로 기록합니다.

유료화·판매 계약·심사 제출은 재개 요청 전까지 보류하고 현재 구매 잠금 해제를 유지하세요. 로컬 옛 메모의 상품 아이디어를 새 승인으로 간주하지 마세요. 전체 SettingsView 진입 버튼을 임의로 복원하지 마세요.

## 인수인계 자료

- `test.md`: 이번 정리 시 실제 실행한 검증과 최근 기기 검증의 한계.
- `temp.md`: 미완료 요청과 설계 선택.
- `build/validation/KIR0923A01/`: 이번 전체 로그·xcresult·정리 전 파일 보존 확인 자료. 로컬 전용이며 새 clone에는 없습니다.
- 중복 개발 문서·구형 재개 프롬프트·HTML 시안은 정리했습니다. 필요한 과거 기록은 `git log --all -- <파일명>` 및 `git show <커밋>:<파일명>`으로 조회하세요.
- 센서 분류 참고·애니메이션 규격의 과거 문서도 Git 이력에 있습니다. 실제 구현은 원본 센서와 공용 frame/phase 계약을 기준으로 읽으세요. 외부 논문·저장소의 코드·모델·데이터를 추가 도입할 때는 현재 라이선스를 별도로 확인하세요.

검증을 완료한 뒤 요청 범위의 변경만 main에 커밋·푸시하고 `git status --porcelain`, `git rev-parse HEAD origin/main`, `git ls-remote origin refs/heads/main`을 확인하세요. 결과 보고에는 검증된 동작과 미확인 기기·정책 항목을 구분하세요.
