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
| 1 | `TaptionPlan/UI/MapHomeTimeSidebar.swift` (동결) | 2,733 | 461 `sidebarBody` | 27 | 115 | 174.3 | 한도의 2.3배, 타입 25개, 본문 461줄 | 타입별 파일, 본문을 구역별로 | 중 | home-ux | 성능 작업 뒤(RFT1116A02 때 성능 세션이 고치는 중) | |
| 2 | `TaptionPlan/Core/RouteTimelineData.swift` (동결) | 2,754 | 191 `requests` | 18 | 36 | 145.3 | 값 타입·색인·예상 경로 엔진(730줄)·타임라인 엔진(1,392줄)이 한 파일 | 값·색인 / 예상 경로 엔진 / 타임라인 엔진(extension으로 둘)로 가름 | 하 | 없음 | 완료 `7dcd30c1` | 641 |
| 3 | `TaptionPlan/UI/SettingsView.swift` (동결) | 2,097 | 455 `body` | 10 | 47 | 135.9 | 본문 455줄, 한 타입 1,402줄 | 구역별 하위 뷰 파일 | 중 | mode-transition | 완료 `77dea72b`(RFT1116A02) — 연결·자주 가는 곳 extension, 장소 상세 화면 파일. `body` 455줄은 그대로 | 826 |
| 4 | `TaptionPlan/Core/PlanningEngine.swift` (동결) | 2,260 | 187 `make` | 29 | 25 | 128.4 | 서로 무관한 엔진 29개(타임라인·메모·목표·관계·날씨·수면) | 주제별 파일 5~6개 | 하 | 없음 | 완료 `d0fff0b9` | 532 |
| 5 | `Packages/TaptionPlanCore/…/DayStoreV3.swift` (동결) | 2,409 | 163 `rawEventPage` | 11 | 13 | 115.9 | actor 하나가 2,127줄 | 값 타입 파일, actor를 원본 사건·outbox·확정 하루 extension으로 | 중(사설 상태 공개 범위) | 없음 | 완료 `2e2fcbc1` | 548 |
| 6 | `TaptionPlanWatch/WatchWorkoutManager.swift` (동결) | 2,336 | 202 `startSensorCollection` | 10 | 10 | 114.7 | 클래스 1,930줄, 보관 actor·취소 도우미 동거 | 도우미 타입 파일, 클래스를 기능 extension으로 | 중(Watch는 빌드로만 확인) | 없음 | 완료 `a8fb9c48` | 972 |
| 7 | `TaptionPlan/Core/WidgetShared.swift` (동결) | 1,679 | 82 | 27 | 40 | 105.4 | 라이브 액티비티·수집 상태·위젯 엔진·고양이·공유 저장소 27개 타입 | 주제별 파일 4~5개(여러 타깃 등록) | 중(타깃 등록) | 없음 | 완료 `30b2fc48` | 458 |
| 8 | `TaptionPlan/UI/AddPlanSheet.swift` (동결) | 2,123 | 141 `body` | 8 | 8 | 98.7 | 시트 1,053줄에 편집기·화면 5개 동거 | 하위 화면별 파일, 시트는 extension으로 | 하 | 없음 | 완료 `613207a4` | 983 |
| 9 | `TaptionPlan/Core/TaptionActivityEngineAdapter.swift` (동결) | 1,872 | 121 | 7 | 30 | 94.7 | enum 하나가 1,424줄 | 잠금 엔진·색인 파일, 어댑터를 주제 extension으로 | 하 | 없음 | 완료 `4bc88223` | 777 |
| 10 | `TaptionPlan/UI/GoalsView.swift` (동결) | 1,832 | 125 | 14 | 6 | 92.5 | 목록·상세(637줄)·슬라이더·작은 부품 동거 | 상세·엔진·슬라이더·부품 파일 | 하 | 없음 | 완료 `38e15e1e` | 518 |
| 11 | `TaptionPlan/UI/MapHomeView+Support.swift` | 1,193 | 451 `presentationModifiers` | 1 | 37 | 91.4 | 시트 연결 함수 하나가 451줄, 옛 지도 여행 모드 코드 | 시트 묶음별 수정자, 죽은 코드 걷기 | 중 | home-ux, mode-transition | 완료 죽은 코드 `f2bf0878`, 가르기 `f30c27f7`(RFT1116A02) — 시트 연결을 수식어 순서 그대로 세 덩어리로 | 631 |
| 12 | `TaptionPlan/UX/AppModel.swift` | 977 | 259 `init` | 1 | 170 | 88.4 | 수정 170회, `init` 259줄 | `init`의 구독·복원 단계를 사설 함수로 | 중(초기화 순서) | 없음 | 완료 `49421478` (`init` 259→154줄) | 984 |
| 13 | `TaptionPlan/Core/WatchConnectivitySupport.swift` | 1,154 | 254 `receiveEnvelope` | 11 | 25 | 88.3 | 정책·저장소 10개와 서비스 881줄, 수신 함수 254줄 | 정책·저장소 파일, 수신 함수를 종류별로 | 중 | 없음 | 완료(파일만) `46a96957` — `receiveEnvelope` 254줄은 그대로 | 884 |
| 14 | `TaptionPlan/UI/AppShellView.swift` (동결) | 1,420 | 106 `body` | 5 | 71 | 88.1 | 한도 초과, 수정 71회 | 시작 관문·잠금 화면 분리 | 중 | mode-transition | 성능 작업 뒤(RFT1116A02 때 성능 세션이 고치는 중) | |
| 15 | `TaptionPlan/UI/MapHomeLocationPresentation.swift` | 1,199 | 102 | 11 | 63 | 86.4 | 한도 1줄 앞, 타입 11개 | 타입별 파일 | 하 | 홈 영역 | 완료 `4a319fc8`(RFT1116A02) | 168 |
| 16 | `TaptionPlan/UX/AppModel+Classification.swift` | 1,160 | 534 `performSensorTimelineRefresh` | 1 | 27 | 86.3 | 함수 하나가 534줄 | 단계별 함수로 쪼개기 | 상(하루 갱신 본줄기) | 없음 | 보류 — 534줄 함수가 지역 되돌리기 상태와 취소 확인을 끝까지 함께 쓰고 직접 시험이 없어, 쪼개면 하루 갱신 결과가 달라질 위험 | 1,160 |
| 17 | `TaptionPlan/Core/TravelModeClassifier.swift` (동결) | 1,368 | 839 `classify` | 1 | 4 | 84.2 | 함수 하나가 839줄 | 판정 단계별 함수로 쪼개기 | 상(분류 결과) | 없음 | 완료(파일만) `bcf9f3e6` — `classify` 839줄은 그대로(판정 순서가 결과라 시험을 먼저 늘린 뒤) | 864 |
| 18 | `TaptionPlanWidget/TaptionPlanWidget.swift` | 1,162 | 148 `body` | 13 | 39 | 83.1 | 제공자·뷰·트랙·고양이·인텐트 동거 | 뷰·트랙·인텐트 파일(위젯 타깃) | 하 | 없음 | 완료 `3bbb1c97` | 175 |
| 19 | `TaptionPlanWatch/WatchConnectivityController.swift` (동결) | 1,620 | 122 | 2 | 16 | 79.6 | 클래스 하나가 1,612줄, 중복 15 | 기능 extension 파일 | 중(Watch는 빌드로만 확인) | 없음 | 완료 `078ff6ef` | 888 |
| 20 | `TaptionPlan/UI/MapHomeLiveMapPolicies.swift` | 1,188 | 75 | 31 | 27 | 79.4 | 정책 타입 31개 | 주제별 파일 | 하 | 홈 영역 | 완료 `32b99917`(RFT1116A02) | 236 |

겹치지 않는 것 14개(2·4~10·12·13·16~19), 합친 뒤 6개(1·3·11·14·15·20).

## 결과 (2026-11-16)

- 완료 13개(커밋 13개, 파일마다 하나), 보류 1개(16), 합친 뒤 6개. 동결 파일 10개가 한도 1,200줄 아래로 내려가 `docs/architecture-baseline.json`의 `frozen_files`에서 뺐습니다.
- 원본 14개 합계 줄 수 24,706 → 10,383(나머지는 새 파일 40개로 옮김). 전체로는 +307줄(파일 머리의 `import`와 `extension` 줄).
- 방법: 줄 범위를 그대로 새 파일로 옮기고, 클래스·actor는 `extension`으로 감쌌습니다. 저장 속성은 원래 타입에 남겼습니다. 다른 파일에서 쓰게 된 `private` 이름만 컴파일러가 알려 준 만큼 internal로 풀었습니다(공개 API·저장 형식·문구·접근성 식별자·번역 키 변경 없음). `extension` 안에 둘 수 없는 저장 상수 하나(`pendingAccelerationChunksFile`)는 같은 값을 돌려주는 계산 속성으로 바꿨습니다.
- 확인: 앱 시험 890개(7개 건너뜀 — 원본 기록 재생용, 자료가 없으면 건너뜀)+103개, `TaptionPlanCore` 패키지 XCTest 89개·Swift Testing 11개(저장 바이트 고정 시험 포함), Watch 스킴 빌드, 구조 점검·import 경계. 14개 묶음을 합친 상태에서 한 번에 돌렸고 중간 커밋 하나하나를 따로 빌드하지는 않았습니다. 실기기 확인 없음.
- 함수 쪼개기는 `AppModel.init`만 했습니다. `classify`(839줄)·`receiveEnvelope`(254줄)·`performSensorTimelineRefresh`(534줄)는 결과를 고정하는 시험을 먼저 늘린 뒤 따로 합니다.

## 결과 2 (RFT1116A02, 2026-11-16)

「합친 뒤」 6개 중 성능 작업과 겹치지 않는 4개를 갈랐고(커밋 4개), 죽은 코드를 걷었습니다(커밋 1개). `MapHomeTimeSidebar`·`AppShellView`는 성능 작업 뒤로 둡니다.

| 원본 | 전 | 후 | 새 파일(줄) |
| --- | ---: | ---: | --- |
| `SettingsView.swift` | 2,096 | 826 | `SettingsView+Connections`(294)·`SettingsView+FrequentPlaces`(342)·`SettingsFrequentPlaceDetailView`(644) |
| `MapHomeView+Support.swift` | 1,195 | 631 | 죽은 코드 −21줄, `MapHomeView+Presentation`(454)·`MapHomeView+Lifecycle`(120) |
| `MapHomeLocationPresentation.swift` | 1,200 | 168 | `MapHomeStickmanAction`(194)·`MapHomeStickmanActionResolver`(607)·`MapHomeStickmanMarker`(237) |
| `MapHomeLiveMapPolicies.swift` | 1,187 | 236 | `MapHomeRouteSpeedGradient`(159)·`MapHomeLiveZoomPolicies`(399)·`MapHomePlaybackDiagnostics`(214)·`MapHomeRenderMemo`(191) |

- 방법은 앞과 같음(줄 범위 그대로, extension, 다른 파일에서 쓰게 된 `private`만 internal: `SettingsView`의 상태 5개·`settingsRow`·옮긴 행 9개·`SettingsTypography`·`UserTransitLocationsSettingsView`·`FrequentPlaceDetailView`). `presentationModifiers`는 `lifecycleModifiers`처럼 수식어 순서 그대로 하루·지도·화면 세 함수로 나눠 겹쳐 부릅니다.
- `SettingsView`가 1,200줄 아래로 내려가 `frozen_files`에서 뺐습니다. 번역 추출기가 읽는 표(`englishName`)는 원래 파일에 남아 경로를 고칠 일이 없었고, 추출·생성 뒤 위젯 카탈로그는 그대로, 앱 카탈로그에서 빠지는 것은 걷은 선택 창 제목 하나뿐입니다(아래).
- 동작 고정 시험: 뷰 파일(`SettingsView`·시트 연결)은 단위 시험으로 고정할 수 없어 Debug 빌드와 전체 시험으로 확인했습니다. 순수 타입(화랑이 판정·줌·캐시)은 기존 시험(`MapHomeStickmanTests`·`MapHomeLiveMapTests` 등)이 있었습니다.

## 옛 「지도 여행 모드」 죽은 코드 (RFT1116A02)

`MapHomeView`의 `@State var isTravelMode = false`와 그것만 쓰는 코드입니다. `main` `edd6222a` 기준으로 닿을 수 없음을 확인하고 걷었습니다.

닿을 수 없는 근거:

- `isTravelMode`에 값을 넣는 곳은 `isTravelMode = false` 두 곳(`travelModeButton`, 여권 `onSelectDay`)뿐입니다. `true`·`toggle()`·`$isTravelMode` 바인딩·`isTravelMode:` 인자는 저장소 어디에도 없습니다(`rg '\$isTravelMode|isTravelMode\s*=\s*true|isTravelMode\.toggle|isTravelMode:'` 결과 0줄). `@State`라 밖에서 넣을 길도 없습니다.
- 여행 단추는 `isTravelMode`가 거짓일 때 `isTravelHomePresented = true`로 `TravelModeView` 전체 화면만 엽니다. 붙여넣거나 중계로 받은 여행 계획도 `TravelModeView`로 가고, 옛 지도 여행 모드로는 가지 않는다는 주석이 이미 있습니다(TVX1116A01).
- 그래서 `isTravelMode`는 늘 거짓이고, 참일 때만 도는 가지와 그 가지에서만 여는 화면은 실행될 수 없습니다.

걷은 곳(동작 변화 없음 — 모두 늘 거짓 쪽 값으로 바꾼 것과 같음):

| 파일 | 걷은 것 |
| --- | --- |
| `MapHomeView.swift` | `isTravelMode`, 여행 모드 하단 「추가」에서만 쓰던 `isTravelAddChoicePresented`·`isTravelPlanPresented`·`isTripImportPresented` 상태 |
| `MapHomePlaceBookTools.swift` | `travelModeButton`의 「일상으로 돌아가기」 가지(동작·모양·접근성 이름 「여행으로 가기」·아래 이름 「일상」은 그대로), `travelBottomBarItems`, `keepSelectedDateInFuture`, `travelModeMinimumDay` |
| `MapHomeView+Support.swift` | 날짜 바뀔 때 `keepSelectedDateInFuture` 호출, 여행 계획 시트·「여행 계획 추가」 선택 창·지도 쪽 「AI로 만들기」 시트, 여권 `onSelectDay`의 끄기 줄, 달력의 `minimumDay` 인자(늘 `nil`이라 기본값과 같음) |
| `MapHomeView+Support2.swift` | 하단 막대의 `if isTravelMode { travelBottomBarItems } else { … }` 가지, 날짜 줄의 `minimumDay` 인자 |
| `MapHomeView+Support3.swift` | 안내 띠 조건의 `!isTravelMode` |
| `MapHomeView+Ledger.swift` | 가계부 `tripID: isTravelMode ? ledgerTripID : nil` → `nil`, `ledgerTripID` |
| `TripImportSheet.swift` | `travelSidebarSegments`. `travelPlanBand`는 `[]`만 돌려주게 남김(아래) |

성능 작업 파일 때문에 남긴 것:

| 파일 | 남긴 것 | 이유 |
| --- | --- | --- |
| `MapHomeView+Timeline.swift` | `planBand: travelPlanBand` 인자 | 성능 작업 파일. `isTravelMode`는 없고 계획 띠만 넘김. 띠는 이제 늘 빔 |
| `MapHomeTimeSidebar.swift` | `planBand: [MapHomeRailPlanSpan]` 속성과 그리기 | 성능 작업 파일. 위와 같이 늘 빈 값을 받음 |

더 걷을 수 있으나 이번에 두는 것(대표·메인 세션 판단):

- `MapHomeTripPlanSheet`(`MapHomePlaceBookTools.swift`, 91줄): 이제 아무도 열지 않는 화면 타입 하나. 타입째 지우면 문구 5개가 번역 카탈로그에서 빠질 수 있어 두었습니다.
- `TravelTripSchedule`·`TravelPlanBand`(+ `MapHomeRailPlanSpan`): 앱에서는 더 쓰지 않거나(앞 둘) 빈 값만 오가지만 단위 시험(`InkWashThemeTests`·`TripItemStatusTests`)이 있는 순수 계산이라 두었습니다. 시간 막대 성능 작업이 끝난 뒤 `planBand`와 함께 걷을 수 있습니다.
- 번역: `extract.py`→`generate.py`를 돌리면 `TaptionPlan/UIText.xcstrings`에서 「여행 계획 추가|Add to trip」 하나가 빠집니다(지운 선택 창의 제목, 다른 곳에서 쓰지 않음). 카탈로그 생성은 메인 세션이 하므로 이 브랜치에서는 카탈로그를 고치지 않았습니다.

## 순서

1. 겹치지 않는 14개를 위험이 낮은 것부터: 타입을 파일로 옮기기만 하는 것(2·4·7·8·9·10·18) → actor·클래스를 extension으로 가르는 것(5·6·13·19) → 긴 함수를 쪼개는 것(12·16·17).
2. 파일마다 관련 단위 시험(없으면 동작을 고정하는 시험을 먼저) → 리팩토링 → 시험과 Debug 빌드 → 커밋 하나. 실패하면 그 파일만 되돌리고 이 표에 이유를 적습니다.
3. 동결 파일은 줄인 만큼 `docs/architecture-baseline.json`의 예산을 낮춥니다.
4. 「합친 뒤」 6개와 죽은 코드는 다른 세션이 `main`에 합쳐진 다음에 합니다.
