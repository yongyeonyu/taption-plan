# 리팩토링 상위 20개 (RFT1116A01)

2026-11-16, `main` `b7f10e96` 기준. 동작·저장 형식·화면·문구·접근성 식별자·번역 키는 바꾸지 않고 구조만 고칩니다.

## 재는 법

대상은 `TaptionPlan/`, `Packages/*/Sources`, 위젯·Watch 타깃, `server/trip-relay/src`의 300줄 이상 파일 290개(전체 708개)입니다. 생성물·번역·시험·자원은 뺐습니다.

| 지표 | 재는 법 | 점수 |
| --- | --- | --- |
| 줄 수 | `wc -l`과 같음 | 줄 수 ÷ 1,200 × 40 (최대 100) |
| 가장 긴 함수 | 중괄호 짝으로 잰 `func`·`init`·계산 속성 길이 | 길이 ÷ 100 × 12 (최대 36) |
| 섞인 책임 | 최상위 타입 수 + 최상위 extension 수 | 개당 0.8 (최대 20) |
| 최근 수정 | `git log --since="3 months ago"`에 나온 횟수 | 회당 0.4 (최대 24) |
| 파일 안 중복 | 공백을 뺀 6줄 창이 같은 파일에서 다시 나온 횟수 | 회당 0.2 (최대 12) |

겹침은 `git diff --name-only main...<브랜치>`(`claude/*` 7개)와 각 작업 폴더의 커밋 안 된 변경으로 확인했습니다. `MapHome*`·`Travel*`·`TripShare*`·`Assistant*`·서버는 지금 변경이 없어도 다른 세션의 영역이라 「합친 뒤」로 둡니다.

새 Swift 파일은 손으로 `project.pbxproj`에 등록해야 합니다(폴더 동기화 방식 아님). `project.pbxproj`는 다른 브랜치도 고치고 있어, 새 줄은 원본 파일 줄 바로 뒤에 넣습니다.

## 표

상태: 완료 / 합친 뒤(다른 세션과 겹침) / 보류(이유) / 대기.

| # | 파일 | 줄 | 최장 함수 | 타입 | 3개월 수정 | 점수 | 문제 | 할 일 | 위험 | 겹침 | 상태 | 뒤 줄 수 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- | --- | ---: |
| 1 | `TaptionPlan/UI/MapHomeTimeSidebar.swift` (동결) | 2,733 | 461 `sidebarBody` | 27 | 115 | 174.3 | 한도의 2.3배, 타입 25개, 본문 461줄 | 타입별 파일, 본문을 구역별로 | 중 | home-ux | 합친 뒤 | |
| 2 | `TaptionPlan/Core/RouteTimelineData.swift` (동결) | 2,754 | 191 `requests` | 18 | 36 | 145.3 | 값 타입·색인·예상 경로 엔진(730줄)·타임라인 엔진(1,392줄)이 한 파일 | 값·색인 / 예상 경로 엔진 / 타임라인 엔진(extension으로 둘)로 가름 | 하 | 없음 | 완료 `7dcd30c1` | 641 |
| 3 | `TaptionPlan/UI/SettingsView.swift` (동결) | 2,097 | 455 `body` | 10 | 47 | 135.9 | 본문 455줄, 한 타입 1,402줄 | 구역별 하위 뷰 파일 | 중 | mode-transition | 합친 뒤 | |
| 4 | `TaptionPlan/Core/PlanningEngine.swift` (동결) | 2,260 | 187 `make` | 29 | 25 | 128.4 | 서로 무관한 엔진 29개(타임라인·메모·목표·관계·날씨·수면) | 주제별 파일 5~6개 | 하 | 없음 | 완료 `d0fff0b9` | 532 |
| 5 | `Packages/TaptionPlanCore/…/DayStoreV3.swift` (동결) | 2,409 | 163 `rawEventPage` | 11 | 13 | 115.9 | actor 하나가 2,127줄 | 값 타입 파일, actor를 원본 사건·outbox·확정 하루 extension으로 | 중(사설 상태 공개 범위) | 없음 | 완료 `2e2fcbc1` | 548 |
| 6 | `TaptionPlanWatch/WatchWorkoutManager.swift` (동결) | 2,336 | 202 `startSensorCollection` | 10 | 10 | 114.7 | 클래스 1,930줄, 보관 actor·취소 도우미 동거 | 도우미 타입 파일, 클래스를 기능 extension으로 | 중(Watch는 빌드로만 확인) | 없음 | 완료 `a8fb9c48` | 972 |
| 7 | `TaptionPlan/Core/WidgetShared.swift` (동결) | 1,679 | 82 | 27 | 40 | 105.4 | 라이브 액티비티·수집 상태·위젯 엔진·고양이·공유 저장소 27개 타입 | 주제별 파일 4~5개(여러 타깃 등록) | 중(타깃 등록) | 없음 | 완료 `30b2fc48` | 458 |
| 8 | `TaptionPlan/UI/AddPlanSheet.swift` (동결) | 2,123 | 141 `body` | 8 | 8 | 98.7 | 시트 1,053줄에 편집기·화면 5개 동거 | 하위 화면별 파일, 시트는 extension으로 | 하 | 없음 | 완료 `613207a4` | 983 |
| 9 | `TaptionPlan/Core/TaptionActivityEngineAdapter.swift` (동결) | 1,872 | 121 | 7 | 30 | 94.7 | enum 하나가 1,424줄 | 잠금 엔진·색인 파일, 어댑터를 주제 extension으로 | 하 | 없음 | 완료 `4bc88223` | 777 |
| 10 | `TaptionPlan/UI/GoalsView.swift` (동결) | 1,832 | 125 | 14 | 6 | 92.5 | 목록·상세(637줄)·슬라이더·작은 부품 동거 | 상세·엔진·슬라이더·부품 파일 | 하 | 없음 | 완료 `38e15e1e` | 518 |
| 11 | `TaptionPlan/UI/MapHomeView+Support.swift` | 1,193 | 451 `presentationModifiers` | 1 | 37 | 91.4 | 시트 연결 함수 하나가 451줄, 옛 지도 여행 모드 코드 | 시트 묶음별 수정자, 죽은 코드 걷기 | 중 | home-ux, mode-transition | 합친 뒤 | |
| 12 | `TaptionPlan/UX/AppModel.swift` | 977 | 259 `init` | 1 | 170 | 88.4 | 수정 170회, `init` 259줄 | `init`의 구독·복원 단계를 사설 함수로 | 중(초기화 순서) | 없음 | 완료 `49421478` (`init` 259→154줄) | 984 |
| 13 | `TaptionPlan/Core/WatchConnectivitySupport.swift` | 1,154 | 254 `receiveEnvelope` | 11 | 25 | 88.3 | 정책·저장소 10개와 서비스 881줄, 수신 함수 254줄 | 정책·저장소 파일, 수신 함수를 종류별로 | 중 | 없음 | 완료(파일만) `46a96957` — `receiveEnvelope` 254줄은 그대로 | 884 |
| 14 | `TaptionPlan/UI/AppShellView.swift` (동결) | 1,420 | 106 `body` | 5 | 71 | 88.1 | 한도 초과, 수정 71회 | 시작 관문·잠금 화면 분리 | 중 | mode-transition | 합친 뒤 | |
| 15 | `TaptionPlan/UI/MapHomeLocationPresentation.swift` | 1,199 | 102 | 11 | 63 | 86.4 | 한도 1줄 앞, 타입 11개 | 타입별 파일 | 하 | 홈 영역 | 합친 뒤 | |
| 16 | `TaptionPlan/UX/AppModel+Classification.swift` | 1,160 | 534 `performSensorTimelineRefresh` | 1 | 27 | 86.3 | 함수 하나가 534줄 | 단계별 함수로 쪼개기 | 상(하루 갱신 본줄기) | 없음 | 완료(RFT1116A03) — 먼저 `SensorTimelineRefreshTests` 7개로 결과·되돌리기·취소를 고정한 뒤, 되돌리기 값은 `SensorRefreshRollbackPoint`, 근거는 `SensorRefreshEvidence`·`SensorRouteEvidence`, 계산 결과는 `SensorDayDerivation`으로 묶어 단계 함수로 나눔. 파일: 갱신 진입·되돌리기 / `+SensorRefreshEvidence`(근거 읽기) / `+SensorRefreshRebuild`(지문 같은 날·다시 만드는 날) / `+ClassifierOutput`(하루 자동 분류) / `+SleepClassification` / `+RecordNaming`. 가장 긴 함수 534→109줄(`applyChargingInactivitySleepRecords`, 옮기기만 함), 갱신 경로에서는 74줄(`deriveSensorDay`) | 160 |
| 17 | `TaptionPlan/Core/TravelModeClassifier.swift` (동결) | 1,368 | 839 `classify` | 1 | 4 | 84.2 | 함수 하나가 839줄 | 판정 단계별 함수로 쪼개기 | 상(분류 결과) | 없음 | 완료(파일만) `bcf9f3e6` — `classify` 839줄은 그대로(판정 순서가 결과라 시험을 먼저 늘린 뒤) | 864 |
| 18 | `TaptionPlanWidget/TaptionPlanWidget.swift` | 1,162 | 148 `body` | 13 | 39 | 83.1 | 제공자·뷰·트랙·고양이·인텐트 동거 | 뷰·트랙·인텐트 파일(위젯 타깃) | 하 | 없음 | 완료 `3bbb1c97` | 175 |
| 19 | `TaptionPlanWatch/WatchConnectivityController.swift` (동결) | 1,620 | 122 | 2 | 16 | 79.6 | 클래스 하나가 1,612줄, 중복 15 | 기능 extension 파일 | 중(Watch는 빌드로만 확인) | 없음 | 완료 `078ff6ef` | 888 |
| 20 | `TaptionPlan/UI/MapHomeLiveMapPolicies.swift` | 1,188 | 75 | 31 | 27 | 79.4 | 정책 타입 31개 | 주제별 파일 | 하 | 홈 영역 | 합친 뒤 | |

겹치지 않는 것 14개(2·4~10·12·13·16~19), 합친 뒤 6개(1·3·11·14·15·20).

## 결과 (2026-11-16)

- 완료 13개(커밋 13개, 파일마다 하나), 보류 1개(16), 합친 뒤 6개. 동결 파일 10개가 한도 1,200줄 아래로 내려가 `docs/architecture-baseline.json`의 `frozen_files`에서 뺐습니다.
- 원본 14개 합계 줄 수 24,706 → 10,383(나머지는 새 파일 40개로 옮김). 전체로는 +307줄(파일 머리의 `import`와 `extension` 줄).
- 방법: 줄 범위를 그대로 새 파일로 옮기고, 클래스·actor는 `extension`으로 감쌌습니다. 저장 속성은 원래 타입에 남겼습니다. 다른 파일에서 쓰게 된 `private` 이름만 컴파일러가 알려 준 만큼 internal로 풀었습니다(공개 API·저장 형식·문구·접근성 식별자·번역 키 변경 없음). `extension` 안에 둘 수 없는 저장 상수 하나(`pendingAccelerationChunksFile`)는 같은 값을 돌려주는 계산 속성으로 바꿨습니다.
- 확인: 앱 시험 890개(7개 건너뜀 — 원본 기록 재생용, 자료가 없으면 건너뜀)+103개, `TaptionPlanCore` 패키지 XCTest 89개·Swift Testing 11개(저장 바이트 고정 시험 포함), Watch 스킴 빌드, 구조 점검·import 경계. 14개 묶음을 합친 상태에서 한 번에 돌렸고 중간 커밋 하나하나를 따로 빌드하지는 않았습니다. 실기기 확인 없음.
- 함수 쪼개기는 `AppModel.init`만 했습니다. `classify`(839줄)·`receiveEnvelope`(254줄)·`performSensorTimelineRefresh`(534줄)는 결과를 고정하는 시험을 먼저 늘린 뒤 따로 합니다.
- RFT1116A03(2026-11-16): `performSensorTimelineRefresh`를 시험을 먼저 더하고 갈랐습니다(16번 줄). 남긴 것: 동작 기록(Core Motion) 분기·HealthKit 경로·Watch 요약·다시 계산(`recomputing`) 분기는 시뮬레이터에서 원본을 넣을 길이 없어 새 시험이 붙잡지 못하고, 코드를 옮기기만 했습니다. 이 파일은 동결 목록에 없어 낮출 예산이 없습니다.

## 따로 적는 후보: 옛 「지도 여행 모드」 죽은 코드

`MapHomeView`의 `isTravelMode` 상태와 그것만 쓰는 코드입니다. `isTravelMode`가 나오는 곳: `MapHomePlaceBookTools.swift` 6, `MapHomeView.swift`·`MapHomeView+Support.swift`·`MapHomeView+Support2.swift`·`MapHomeView+Ledger.swift`·`TripImportSheet.swift` 각 1. 모두 다른 세션이 고치는 영역이라 「합친 뒤」에 한 커밋으로 걷습니다.

## 순서

1. 겹치지 않는 14개를 위험이 낮은 것부터: 타입을 파일로 옮기기만 하는 것(2·4·7·8·9·10·18) → actor·클래스를 extension으로 가르는 것(5·6·13·19) → 긴 함수를 쪼개는 것(12·16·17).
2. 파일마다 관련 단위 시험(없으면 동작을 고정하는 시험을 먼저) → 리팩토링 → 시험과 Debug 빌드 → 커밋 하나. 실패하면 그 파일만 되돌리고 이 표에 이유를 적습니다.
3. 동결 파일은 줄인 만큼 `docs/architecture-baseline.json`의 예산을 낮춥니다.
4. 「합친 뒤」 6개와 죽은 코드는 다른 세션이 `main`에 합쳐진 다음에 합니다.
