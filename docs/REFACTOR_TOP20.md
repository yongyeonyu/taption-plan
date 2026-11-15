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
| 2 | `TaptionPlan/Core/RouteTimelineData.swift` (동결) | 2,754 | 191 `requests` | 18 | 36 | 145.3 | 값 타입·색인·예상 경로 엔진(730줄)·타임라인 엔진(1,392줄)이 한 파일 | 값·색인 / 예상 경로 엔진 / 타임라인 엔진(extension으로 둘)로 가름 | 하 | 없음 | 대기 | |
| 3 | `TaptionPlan/UI/SettingsView.swift` (동결) | 2,097 | 455 `body` | 10 | 47 | 135.9 | 본문 455줄, 한 타입 1,402줄 | 구역별 하위 뷰 파일 | 중 | mode-transition | 합친 뒤 | |
| 4 | `TaptionPlan/Core/PlanningEngine.swift` (동결) | 2,260 | 187 `make` | 29 | 25 | 128.4 | 서로 무관한 엔진 29개(타임라인·메모·목표·관계·날씨·수면) | 주제별 파일 5~6개 | 하 | 없음 | 대기 | |
| 5 | `Packages/TaptionPlanCore/…/DayStoreV3.swift` (동결) | 2,409 | 163 `rawEventPage` | 11 | 13 | 115.9 | actor 하나가 2,127줄 | 값 타입 파일, actor를 원본 사건·outbox·확정 하루 extension으로 | 중(사설 상태 공개 범위) | 없음 | 대기 | |
| 6 | `TaptionPlanWatch/WatchWorkoutManager.swift` (동결) | 2,336 | 202 `startSensorCollection` | 10 | 10 | 114.7 | 클래스 1,930줄, 보관 actor·취소 도우미 동거 | 도우미 타입 파일, 클래스를 기능 extension으로 | 중(Watch는 빌드로만 확인) | 없음 | 대기 | |
| 7 | `TaptionPlan/Core/WidgetShared.swift` (동결) | 1,679 | 82 | 27 | 40 | 105.4 | 라이브 액티비티·수집 상태·위젯 엔진·고양이·공유 저장소 27개 타입 | 주제별 파일 4~5개(여러 타깃 등록) | 중(타깃 등록) | 없음 | 대기 | |
| 8 | `TaptionPlan/UI/AddPlanSheet.swift` (동결) | 2,123 | 141 `body` | 8 | 8 | 98.7 | 시트 1,053줄에 편집기·화면 5개 동거 | 하위 화면별 파일, 시트는 extension으로 | 하 | 없음 | 대기 | |
| 9 | `TaptionPlan/Core/TaptionActivityEngineAdapter.swift` (동결) | 1,872 | 121 | 7 | 30 | 94.7 | enum 하나가 1,424줄 | 잠금 엔진·색인 파일, 어댑터를 주제 extension으로 | 하 | 없음 | 대기 | |
| 10 | `TaptionPlan/UI/GoalsView.swift` (동결) | 1,832 | 125 | 14 | 6 | 92.5 | 목록·상세(637줄)·슬라이더·작은 부품 동거 | 상세·엔진·슬라이더·부품 파일 | 하 | 없음 | 대기 | |
| 11 | `TaptionPlan/UI/MapHomeView+Support.swift` | 1,193 | 451 `presentationModifiers` | 1 | 37 | 91.4 | 시트 연결 함수 하나가 451줄, 옛 지도 여행 모드 코드 | 시트 묶음별 수정자, 죽은 코드 걷기 | 중 | home-ux, mode-transition | 합친 뒤 | |
| 12 | `TaptionPlan/UX/AppModel.swift` | 977 | 259 `init` | 1 | 170 | 88.4 | 수정 170회, `init` 259줄 | `init`의 구독·복원 단계를 사설 함수로 | 중(초기화 순서) | 없음 | 대기 | |
| 13 | `TaptionPlan/Core/WatchConnectivitySupport.swift` | 1,154 | 254 `receiveEnvelope` | 11 | 25 | 88.3 | 정책·저장소 10개와 서비스 881줄, 수신 함수 254줄 | 정책·저장소 파일, 수신 함수를 종류별로 | 중 | 없음 | 대기 | |
| 14 | `TaptionPlan/UI/AppShellView.swift` (동결) | 1,420 | 106 `body` | 5 | 71 | 88.1 | 한도 초과, 수정 71회 | 시작 관문·잠금 화면 분리 | 중 | mode-transition | 합친 뒤 | |
| 15 | `TaptionPlan/UI/MapHomeLocationPresentation.swift` | 1,199 | 102 | 11 | 63 | 86.4 | 한도 1줄 앞, 타입 11개 | 타입별 파일 | 하 | 홈 영역 | 합친 뒤 | |
| 16 | `TaptionPlan/UX/AppModel+Classification.swift` | 1,160 | 534 `performSensorTimelineRefresh` | 1 | 27 | 86.3 | 함수 하나가 534줄 | 단계별 함수로 쪼개기 | 상(하루 갱신 본줄기) | 없음 | 대기 | |
| 17 | `TaptionPlan/Core/TravelModeClassifier.swift` (동결) | 1,368 | 839 `classify` | 1 | 4 | 84.2 | 함수 하나가 839줄 | 판정 단계별 함수로 쪼개기 | 상(분류 결과) | 없음 | 대기 | |
| 18 | `TaptionPlanWidget/TaptionPlanWidget.swift` | 1,162 | 148 `body` | 13 | 39 | 83.1 | 제공자·뷰·트랙·고양이·인텐트 동거 | 뷰·트랙·인텐트 파일(위젯 타깃) | 하 | 없음 | 대기 | |
| 19 | `TaptionPlanWatch/WatchConnectivityController.swift` (동결) | 1,620 | 122 | 2 | 16 | 79.6 | 클래스 하나가 1,612줄, 중복 15 | 기능 extension 파일 | 중(Watch는 빌드로만 확인) | 없음 | 대기 | |
| 20 | `TaptionPlan/UI/MapHomeLiveMapPolicies.swift` | 1,188 | 75 | 31 | 27 | 79.4 | 정책 타입 31개 | 주제별 파일 | 하 | 홈 영역 | 합친 뒤 | |

겹치지 않는 것 14개(2·4~10·12·13·16~19), 합친 뒤 6개(1·3·11·14·15·20).

## 따로 적는 후보: 옛 「지도 여행 모드」 죽은 코드

`MapHomeView`의 `isTravelMode` 상태와 그것만 쓰는 코드입니다. `isTravelMode`가 나오는 곳: `MapHomePlaceBookTools.swift` 6, `MapHomeView.swift`·`MapHomeView+Support.swift`·`MapHomeView+Support2.swift`·`MapHomeView+Ledger.swift`·`TripImportSheet.swift` 각 1. 모두 다른 세션이 고치는 영역이라 「합친 뒤」에 한 커밋으로 걷습니다.

## 순서

1. 겹치지 않는 14개를 위험이 낮은 것부터: 타입을 파일로 옮기기만 하는 것(2·4·7·8·9·10·18) → actor·클래스를 extension으로 가르는 것(5·6·13·19) → 긴 함수를 쪼개는 것(12·16·17).
2. 파일마다 관련 단위 시험(없으면 동작을 고정하는 시험을 먼저) → 리팩토링 → 시험과 Debug 빌드 → 커밋 하나. 실패하면 그 파일만 되돌리고 이 표에 이유를 적습니다.
3. 동결 파일은 줄인 만큼 `docs/architecture-baseline.json`의 예산을 낮춥니다.
4. 「합친 뒤」 6개와 죽은 코드는 다른 세션이 `main`에 합쳐진 다음에 합니다.
