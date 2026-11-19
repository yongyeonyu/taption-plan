---
id: 20261119-1943-energy-curve-visualizer
created_at: 2026-11-19T19:43+09:00
status: done
request_id: ENC1119A01
finished_at: 2026-11-19T21:10+09:00
commit: 40bd53b9
title: 컨디션×일정 에너지 곡선 — 하루 요약에 비주얼라이저 카드 추가
from: 비야
basis: 대표 선택(2026-11-14 「3개다」 — 신규 비주얼라이저 3종 중 2번) · 비야 제안(구현 범위·형태) · 2026-11-19 비야 브리지 배정
---

## 할 일

0. `git pull --rebase` 뒤 이 문서를 읽고, `AGENTS.md` 2절대로 요청 ID를 새로 만들어 `test.md` `## 남은 작업` 중 **홈·UI**에 한 줄, `### 요청 상세`에 원인(신규 기능이라 「없음」)·해결·검증 기준·상태를 먼저 적습니다. 이 문서에는 `request_id`가 없습니다.

1. 지금 상태 (2026-11-19 `origin/main` `a6bb198`에서 직접 확인함)

   1-1. **화면** — 하루 요약 시트는 `TaptionPlan/UI/MapHomeInfoSheets.swift`의 `MapHomeDaySummarySheet`(241행부터, 파일 575줄)이고, 본문 `summaryContent`(415행)의 순서는 432행 집 성장 카드 → 442행 연봉 카드 → 446행 메모 줄 → 458행 걸음 수 → 473행 대분류 막대(없으면 「이 날의 기록이 아직 없습니다」) → 이동 거리 → `LedgerDaySummarySection` → 집 범위 편집입니다. 호출부는 `TaptionPlan/UI/MapHomeView+Presentation.swift:42`의 `.mapHomeWidePanel(isPresented: $isDaySummaryPresented …)` 한 곳뿐이고, 아이패드 넓은 화면에서는 같은 시트가 패널로 뜹니다(`@Environment(\.mapHomeIsWidePanel)`).

   1-2. **자료** — 새로 수집하거나 서버에 묻지 않고, 앱이 이미 들고 있는 값만 씁니다.
   - 지난밤 수면: `model.sleepSessions: [SleepSession]`(`TaptionPlan/UX/AppModel.swift:209`). `SleepSession`은 `span`·`asleepDuration`·`awakeDuration`·`inBedDuration`·`stageDurations[SleepStage: TimeInterval]`·`sleepEfficiency`·`segments`를 갖습니다(`Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/HealthAndSensorModels.swift:87`).
   - 일정: `model.snapshot.plans`(`PlanRecord` — `span`·`title`·`categoryID`·`externalEventID`·`status`)와 `dayCalendarEventsForSelectedDate`(`MapHomeView+Memos.swift:174`. `loadDayCalendarEvents()`가 그날 것을 채우고, 날짜를 바꾼 직후에는 빈 목록으로 내려 이전 날 일정이 남지 않게 합니다). 앱 계획만 볼 때의 기존 규칙은 `MapHomeTodoPanelRow.plans(_:on:)`(`TaptionPlan/UI/LedgerMemoPanel.swift:417`) — 달력에서 온 계획(`externalEventID != nil`)은 달력 일정과 겹치므로 빼고, `span.start`가 그날인 것만 봅니다. 이번 카드는 **그날과 겹치는 구간**을 봐야 하므로 시작이 전날인 계획도 넣되, 달력에서 온 계획은 빼고 `dayCalendarEventsForSelectedDate`의 일정으로 한 번만 셉니다(`isAllDay == true`는 뺀다).
   - 실제 기록: `currentDayDataSnapshot`(`PlanDayDataSnapshot` — `actuals`·`places`·`travel`·`readings`). 분류는 `RecordAnalysisCategoryPolicy.categoryID(for:)`(`TaptionPlan/Core/RecordSummaryEngine.swift`), 걸음은 `ClassifierAdapter.stepCount(readings:in:)`(`TaptionPlan/Core/ClassifierAdapter.swift:357`. 워치가 덮은 시간은 워치 걸음만 셉니다).
   - **다른 날 자료가 섞이지 않게**: 하루 요약은 `date == model.selectedDate`일 때 뜨지만, 과거 날짜에서는 `currentDayDataSnapshot`이 그날 것이 아닐 수 있습니다. `currentDayDataSnapshot.day`(자정 기준)가 카드의 날짜와 다르면 `model.snapshot.actuals`·`travel`에서 그날 것만 걸러 씁니다. 걸러 낸 자료가 없으면 곡선을 그리지 않고 빈 상태를 보입니다(`dayCalendarEventsForSelectedDate`가 이전 날 목록을 내리는 것과 같은 이유).

   1-3. **중복 확인(했음)** — 저장소에 `컨디션`·`EnergyCurve`·`import Charts`가 0건입니다. 차트는 `Canvas`·`Path`로 직접 그립니다(`MapHomeTimeSidebar`·`MapHomeFogLayer`·`MapHomePassportBook`). 하루 요약은 이미 대분류 시간 막대를 그리지만 **시간축 위의 곡선은 없습니다.** 심박·HRV·안정시심박은 날짜별로 저장하지 않으므로(라이브 활동 요약의 최신 값뿐) 이번 곡선의 입력으로 쓰지 않습니다. 시작할 때 같은 카드가 이미 들어가 있으면(하루 요약에 에너지 곡선이 보이면) 중복으로 만들지 말고 그 커밋·상태만 회신하고 이 문서를 `done/`으로 옮깁니다.

2. **새 파일 3개** (이름은 읽는 쪽이 분명하면 바꿔도 되고, 바꿨으면 회신에 적습니다)
   - `TaptionPlan/Core/EnergyCurveEngine.swift` — 순수 계산. SwiftUI·저장소 타입을 import하지 않고 Foundation만 씁니다.
   - `TaptionPlan/UI/MapHomeEnergyCurveCard.swift` — 카드 뷰 + `MapHomeView`에서 입력을 모으는 extension + 문구.
   - `TaptionPlanTests/EnergyCurveTests.swift` — 단위 시험.
   - 셋 다 `TaptionPlan.xcodeproj/project.pbxproj`에 등록합니다(앱 target 2개, 시험 target 1개 — `PBXBuildFile`·`PBXFileReference`·그룹 children·Sources 단계 네 곳. `ANN1119A01` 커밋이 넣은 방식 그대로). 각 파일은 1,200줄을 넘기지 않습니다(넘으면 `architecture-metrics.py --check`가 「새 거대 파일」로 실패).
   - 기존 동작 코드는 `MapHomeInfoSheets.swift`에 카드 한 줄과 파라미터 하나, `MapHomeView+Presentation.swift`에 인자 하나만 더합니다. `MapHomeView.swift`(본 파일)에 저장 속성을 더하지 않습니다 — 카드가 자기 `@State`를 들고 `.task(id:)`로 값을 받는 `MapHomeDailyCardSheet` 방식(`MapHomeDailyCard.swift`)을 그대로 따릅니다.

3. **엔진 계약** — 아래 모양을 기준으로 하되, 더 나은 이름·표현이 있으면 값 타입 경계를 지키는 선에서 바꿉니다.

   ```swift
   // 입력: 화면이 모아 넘긴다. 엔진은 Date·TimeSpan·값 타입만 본다.
   struct EnergyCurveInput {
       let day: TimeSpan                  // 로컬 시간대 기준 그날 [00:00, 다음 00:00)
       let asOf: Date                     // 이 시각까지가 실제, 이후는 예측. 시험은 고정값을 넣는다
       let sleep: EnergyCurveSleep?       // 지난밤 (asleep: TimeInterval, deep: TimeInterval, efficiency: Double?)
       let segments: [EnergyCurveSegment] // 실제 기록 (span, kind)
       let blocks: [EnergyCurveBlock]     // 일정 (span, kind, title은 화면 몫이라 넣지 않아도 된다)
       let stepsByBucket: [Int: Int]?     // 선택: 15분 칸 걸음 수
   }

   enum EnergyCurveActivityKind: String { case rest, sleep, eating, work, study, hobby, housework, movement, exercise, unconfirmed }
   // categoryID → kind 매핑은 엔진 안의 순수 함수 하나로 둔다(“work”·“study”·“hobby”·“exercise”·“movement”·“eating”·“housework”·“sleep”·“unconfirmed”, 그 밖은 .rest)
   ```

   ```swift
   enum EnergyCurveEngine {
       static func curve(_ input: EnergyCurveInput) -> EnergyCurveResult
   }

   struct EnergyCurveResult: Equatable {
       let buckets: [EnergyCurveBucket]       // 15분 칸. 그날 길이에 따라 92~100칸
       let insights: [EnergyCurveInsight]     // 0~2개, 우선순위 순
       let wakeMinute: Int?                   // 기상 시각(자정부터 분). 없으면 nil
       let hasSleepData: Bool
       var isEmpty: Bool { buckets.isEmpty }
   }

   struct EnergyCurveBucket: Equatable {
       let start: Date
       let value: Double?    // 0…1. 자료가 없어 그리지 않는 칸은 nil
       let isProjected: Bool // asOf 뒤
       let isAsleep: Bool    // 수면 구간에 덮인 칸
   }

   enum EnergyCurveInsight: Equatable {
       case lowestPoint(minute: Int, value: Double)             // 그날 가장 낮은 칸
       case scheduleStack(minute: Int, blockCount: Int, seconds: TimeInterval) // 그 무렵 일정이 겹침
       case shortSleep(minutes: Int)                            // 지난밤 6시간 미만
       case missingSleep                                        // 수면 기록 없음(기본값으로 그림)
       case noData                                              // 그릴 것이 하나도 없음
   }
   ```

   - **칸**: 15분(900초) 고정, 그날의 자정부터. `Calendar`는 `MapHomeGrowthPolicy.localCalendar`와 같은 로컬 시간대를 쓰고, 그날 길이가 24시간이 아니면(DST) 칸 수가 92~100으로 달라지는 것을 허용합니다. 자정을 넘긴 기록·일정은 이 날 몫만 잘라 넣고, 두 번 세지 않습니다.
   - **기상 기준점**: ① 그날 수면 세션 중 `span.end`가 가장 늦은 것의 끝, ② 없으면 그날 첫 기록, ③ 둘 다 없으면 07:00.
   - **시작값(0…1)**: 수면 시간(목표 420분)·깊은잠 비중(목표 15%)·수면 효율(0.85 이상)로 만듭니다. 예: `0.72 × clamp(asleep/420, 0.55, 1.05) + 0.05 × clamp(deep/420, 0, 0.2)/0.2 + 0.05 × clamp((efficiency-0.75)/0.2, 0, 1)`, 0.35…1.0으로 자름. 수면 기록이 없으면 0.75에서 시작하고 `.missingSleep` 인사이트를 붙입니다.
   - **칸마다 더하는 변화량(시간당, 제안값)**: 기본 소모 −0.055 · 서카디안 처짐 14:30 중심 가우시안(σ 2시간) −0.06 · 수면(낮잠) +0.12 · 휴식 +0.05 · 식사 +0.02 · 취미 +0.03 · 공부 −0.04 · 업무 −0.05 · 집안일 −0.07 · 이동 −0.06 · 운동 −0.16 · 미확인 0. 한 칸에 여러 기록이 겹치면 각 기록이 칸을 덮은 비율만큼 더하고, 칸 합은 −0.15…+0.15로 자릅니다. 결과는 0…1로 자르고 NaN을 만들지 않습니다(0으로 나누는 자리 주의).
   - **일정**: `blocks`는 곡선을 흔들지 않고 위에 띠로만 그립니다(계획과 실제가 섞이지 않게). `asOf` 뒤는 기록 대신 그 시간의 `blocks` 종류로 같은 규칙을 이어 붙이고 `isProjected = true`로 표시합니다. 오늘은 「지금까지 실제 + 남은 일정 예측」, 지난 날은 전부 실제입니다.
   - **인사이트(최대 2개, 순서 고정)**: ① 곡선 최저 칸(값 0.35 미만일 때만) ② 그 최저 칸 ±90분에 일정이 2건 이상 겹치면 `scheduleStack` ③ 지난밤 6시간 미만이면 `shortSleep` ④ 수면 기록이 없으면 `missingSleep`. 문장은 엔진이 만들지 않습니다(아래 5절).
   - **상수는 한 곳에**: 위 수치는 `enum EnergyCurveTuning` 한 곳에 모읍니다. 시험은 정확한 값이 아니라 관계(단조성·범위·칸 수·인사이트 종류)를 확인하므로, 더 나은 근거가 있으면 상수만 바꿔도 시험이 깨지지 않게 씁니다.

4. **카드 UI** — `MapHomeEnergyCurveCard`
   - 모양: 제목 「컨디션 에너지 곡선」/「Condition energy curve」 + 부제(그날 지난밤 수면 요약, 없으면 날짜) → 곡선 영역(높이 120~150pt, 폭은 시트 폭) → 일정 띠 → 인사이트 줄 1~2개. 기존 하루 요약 카드처럼 `taptionRaised(.rounded(TaptionCorner.large), fill: Color.tpSurface, gloss: false)` 위에 올립니다.
   - 곡선: `Canvas`로 그립니다(`import Charts`를 새로 넣지 않는다). 실제 구간은 실선 + 아래 옅은 면(`Color.tpAccent.opacity(0.12)`), `asOf` 뒤는 점선(`StrokeStyle(dash: [4, 4])`). y축은 0·50·100 라벨만, x축 눈금은 0·6·12·18·24시(좁은 폭에서는 0·12·24). 글자는 `TaptionType.scaled(TaptionType.snapped(11))` 정도.
   - 일정 띠: 곡선 아래 12pt 레인에 일정 블록을 시간 비율로 그리고, 블록이 2건 이상 겹치면 위아래로 나눠 그립니다. 색은 기존 분류 색 헬퍼가 있으면 재사용하고 없으면 `Color.tpReferenceBlue` 계열 한 색으로 통일합니다. 블록이 3개를 넘으면 띠는 그대로 그리고 이름표는 붙이지 않습니다.
   - 수면 구간: 곡선 배경에 `Color.tpLine.opacity(0.35)` 띠로 깔아 「이때는 자고 있었다」가 한눈에 보이게 합니다.
   - 인사이트 문구(리터럴, `language.text`): `lowestPoint` → 「\\(시각) 무렵 가장 낮아요 · 에너지 \\(값)%」, `scheduleStack` → 「그 무렵 일정 \\(건)건(\\(시간))이 겹쳐요」, `shortSleep` → 「어젯밤 \\(시간)밤잠이라 시작이 낮아요」, `missingSleep` → 「어젯밤 수면 기록이 없어 기본값으로 그렸어요」, `noData` → 「이 날은 그릴 기록이 없어요」. 시간은 `MapHomeAlarmPolicy.timeText(_:language:)`, 길이는 `DurationText.localized(_:english:)`(`RecordSummaryEngine.swift`)를 씁니다 — `MapHomeAlarmPolicy.hoursText`는 한국어만 만들므로 쓰지 않습니다.
   - 빈 상태: 곡선 대신 한 줄(`noData`)과 가는 안내만. 카드 높이가 줄어도 레이아웃이 흔들리지 않게 `frame(minHeight:)`을 고정합니다.
   - 접근성: 카드 `.accessibilityElement(children: .contain)`, `accessibilityIdentifier("daySummaryEnergyCurve")`, 빈 상태는 `"daySummaryEnergyCurveEmpty"`. 곡선·띠 그림은 `.accessibilityHidden(true)`이고, 대신 카드 라벨에 「가장 낮은 때 \\(시각) \\(값)%, 일정 \\(건)건」을 넣습니다. 카드 본문은 `Equatable`로 값이 같으면 다시 그리지 않습니다.
   - 색은 `Color.tp*`만 씁니다(하드코딩 금지, 다크 모드 대응). 글자는 `.taptionFixed` + `TaptionType.scaled`로 Dynamic Type을 따릅니다.

5. **연결(동작 코드는 세 곳만)**
   - `MapHomeDaySummarySheet`에 `var makeEnergyCurve: (@MainActor (Date) async -> EnergyCurveResult?)? = nil` 하나를 더하고, `summaryContent`의 442~446행 사이(연봉 카드 다음, 메모 줄 앞)에 `if let makeEnergyCurve { MapHomeEnergyCurveCard(day: date, language: language, make: makeEnergyCurve) }`를 넣습니다. 값이 없으면 카드를 그리지 않습니다(다른 호출부·미리보기 안전).
   - `MapHomeView+Presentation.swift`의 시트 호출에 `makeEnergyCurve: { day in await energyCurve(for: day) }`를 넘깁니다.
   - `MapHomeEnergyCurveCard.swift` 안의 `extension MapHomeView`에 `@MainActor func energyCurve(for day: Date) async -> EnergyCurveResult?`를 둡니다: 그날 수면 세션 고르기(그날 0시부터 12시간 전 ~ 그날 12시 사이에 `span`이 겹치는 것 중 `asleepDuration`이 가장 큰 것) → 계획·달력 일정 모으기 → `RecordAnalysisCategoryPolicy`로 기록 분류 → 15분 칸 걸음은 그날 `readings` 전체와 칸 구간으로 `ClassifierAdapter.stepCount(readings:in:)`를 부릅니다(칸마다 전체를 다시 훑으므로, 하루 표본이 아주 많아 느리면 한 번만 도는 계산으로 바꾸되 시험에서 칸 합이 하루 합과 같은지 확인).
   - 다시 계산은 시트가 열릴 때·날짜가 바뀔 때·자료가 바뀔 때만: 카드 안 `@State` + `.task(id: MapHomeEnergyCurveKey)`(날짜, `model.dayProjectionRevision`, `sleepSessions.count`, 일정 목록의 날짜·건수). `body`에서 매번 다시 세지 않습니다(`AGENTS.md` 3절).

6. **단위 시험** — `TaptionPlanTests/EnergyCurveTests.swift`(XCTest, `@testable import TaptionPlan`, 고정 날짜·고정 `asOf`, 실제 좌표·이름 없이 가짜 값만).
   1. 보통 날: 칸이 96개, 첫 칸 `start`가 그날 0시, 마지막 칸이 24시 전, 모든 값이 0…1.
   2. 빈 데이터: 수면·기록·일정이 모두 없으면 `buckets`가 비고(`isEmpty == true`) `insights == [.noData]`이며 값이 하나도 없다. 카드는 이 한 가지로 빈 상태를 그린다.
   3. 기상 뒤 단조 감소: 수면만 넣고 기록이 없으면 기상 뒤 값이 오르지 않고, 시작값이 0.35…1.0.
   4. 일정·기록의 영향: 같은 날 오전을 업무로 채운 경우와 휴식으로 채운 경우를 비교해 18시 값이 업무 쪽이 더 낮다.
   5. 낮잠: 오후 수면 구간을 넣으면 그 뒤 값이 직전보다 높고, 어떤 값도 1.0을 넘지 않는다.
   6. 자정·시간대 경계: 자정을 넘긴 기록은 이 날 몫만 반영되고 두 번 세지 않는다. DST가 있는 시간대(예: `America/New_York` 2026-11-01)에서 칸 수가 그날 실제 길이와 맞는다.
   7. 일정 인사이트: 최저 칸과 겹치는 일정이 2건 이상일 때만 `scheduleStack`, 1건이면 붙지 않는다. 종일 일정은 화면에서 걸러지므로 엔진에는 들어오지 않는다는 것을 시험 입력으로 확인.
   8. 과한 입력: 18시간 운동처럼 극단값에서도 0…1을 벗어나지 않고 NaN·무한대가 없다.
   9. 같은 입력 두 번 → 같은 결과(엔진 안에서 `Date.now`를 읽지 않는다).
   - 실행: 먼저 새 시험만(`-only-testing:TaptionPlanTests/EnergyCurveTests`) 돌려 통과를 확인하고, 이어서 7절대로 `-only-testing:TaptionPlanTests` 전체를 돌립니다.

7. **검증**
   - `AGENTS.md` 5절 빌드 잠금(`/tmp/taptionplan-xcodebuild.lock`, `owner`에 「요청ID pid」) 안에서: 앱 Debug 빌드 → `-only-testing:TaptionPlanTests`(시뮬레이터 `99AC6F35-6B50-4741-A11D-1A46E1F7F4BD`, `-parallel-testing-enabled NO`). 실제 실행·통과·실패·건너뜀 수치는 xcresult로 읽어 회신에 적습니다.
   - 이미 실패 중인 항목(`TravelModeView` actor 격리, `DayStoreV3Tests` 간헐 실패)은 이번 변경과 섞지 말고 **따로** 적습니다. 새로 깨진 시험이 있으면 그것부터 고칩니다.
   - `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json` 통과. `docs/architecture-baseline.json`은 이번에 바꾸지 않습니다(동결 파일을 키우지 않으므로 예산을 낮출 것도 없습니다).

8. **문구·번역**
   - 새 문구는 전부 `language.text("한국어", "English")` 리터럴로 씁니다(변수로 받은 문구만 `runtimeText`).
   - `UIText.xcstrings`·`Localizable`을 손으로 고치지 않습니다. `python3 scripts/l10n/extract.py`로 새 키가 `scripts/l10n/source.json`에 들어가고 `unread-report.json`에 읽지 못한 호출이 없는지 확인한 뒤 `python3 scripts/l10n/check.py`를 돌리고, 12개 언어의 새 문구 누락은 **「번역 대기」로 회신에 목록만 적습니다**(`generate.py`는 메인 세션 몫이라 돌리지 않는다).

9. `test.md` `## 실기기 확인 목록`에 아이폰 11 Pro 줄을 넣습니다 — 「하루 요약 › 연봉 카드 아래 컨디션 에너지 곡선: 곡선·일정 띠·인사이트 1~2줄이 보이고, 기록 없는 날은 한 줄 빈 상태, 날짜를 바꿔도 이전 날 곡선이 남지 않음」. 시뮬레이터로 본 화면과 기기 확인을 구분해 적습니다.

10. `pickle-bridge/README.md` 4절 회신 형식대로 `## 클로드 코드 회신`을 적고, frontmatter를 `status: done`·`finished_at`·`commit`으로 채운 뒤 `git mv`로 `pickle-bridge/done/`에 옮겨 커밋·푸시합니다(작업 커밋과 문서 이동 커밋 분리, 경로를 지정해 커밋).

## 확인 기준

- 하루 요약에서 그날의 에너지 곡선·일정 띠·인사이트 1~2줄이 한 카드로 보이고, 곡선은 시간축(0~24시) 위에 그려진다.
- 곡선은 그날 기록과 지난밤 수면에서만 만들어지고, 다른 날 자료가 섞이지 않는다(날짜를 바꾼 직후 이전 날 곡선이 남지 않는다).
- 기록·일정·수면이 모두 없는 날은 곡선 없이 한 줄로 끝나고, 앱이 멈추거나 NaN을 그리지 않는다.
- 엔진이 순수 값 타입만 받고 SwiftUI·저장소 타입을 모른 채 시험된다. 시험이 6절 항목을 모두 덮고, 새 시험이 실제로 실행된 수치가 회신에 있다.
- 앱 Debug 빌드와 `-only-testing:TaptionPlanTests` 결과가 xcresult 수치로 적혀 있고, 기존 실패 항목과 구분돼 있다.
- `architecture-metrics.py --check` 통과, 동결 파일 5개 무변경, 새 파일이 각각 1,200줄 미만.
- 새 문구가 `language.text` 리터럴이고, 12개 언어 누락은 「번역 대기」로만 보고돼 있다.
- 작업 커밋 해시·바꾼 파일·푸시 상태가 회신에 적혀 있다.

## 하지 말 것

- 동결 파일 수정 — `docs/architecture-baseline.json`의 `frozen_files` 5개: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`. 곡선을 시간 사이드바나 지도 캔버스에 넣지 않습니다.
- `MapHomeView.swift`(본 파일)에 `@State`·저장 속성 더하기. 새 상태는 새 파일 안 카드가 듭니다.
- `server/trip-relay` 수정, 서버 배포, TestFlight 업로드, 계정·결제, 파일 삭제(`AGENTS.md` 12절·`pickle-bridge/README.md` 6절).
- HealthKit 권한을 새로 요청하거나 읽기 허용 목록(`TaptionHealthReadScope`)을 넓히기. 심박·HRV·안정시심박을 새로 수집·저장하기. 이번 곡선은 이미 저장된 수면·기록·일정·걸음만 씁니다.
- 좌표·장소 이름·실제 동네/가게 이름을 카드나 시험에 넣기. 곡선은 시간만 씁니다(저장소는 공개이고, 좌표는 AI·서버·분석으로 보내지 않는다 — `AGENTS.md` 3·8절).
- `import Charts`나 새 패키지 의존성 더하기. `UIText.xcstrings`·`Localizable`·`translations/*.json` 손으로 고치기, `generate.py` 돌리기.
- `MapHomeDailyCard`(공유 카드)·`LedgerSummaryPanel`·하루 요약의 기존 줄 모양 바꾸기. 카드 하나만 더합니다.
- 다른 세션의 미커밋 변경(예: `TaptionPlan/Assets.xcassets/PlaceBook/.../PlaceBook_kr_sungnyemun.svg`)을 이번 커밋에 넣기. 작업 폴더에 이미 수정된 파일이 있으면 경로를 지정해 이번에 만진 파일만 커밋합니다.

## 참고

- `pickle-bridge/README.md`, `AGENTS.md` 2·3·5·8·12절, `DEVELOPMENT.md` 「검증 명령」.
- 화면: `TaptionPlan/UI/MapHomeInfoSheets.swift`(`MapHomeDaySummarySheet` 241행, `summaryContent` 415행), `MapHomeView+Presentation.swift:42`(시트 호출), `MapHomeDailyCard.swift`(자기 `@State`로 값을 받는 시트 패턴), `MapHomeDaySummaryBand.swift`(값 캐시와 `Key: Equatable` 패턴), `MapHomePassportBook.swift`·`MapHomeTimeSidebar.swift`(Canvas 그리기 예).
- 자료: `TaptionPlan/UX/AppModel.swift:209`(`sleepSessions`), `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/HealthAndSensorModels.swift:87`(`SleepSession`), `Packages/TaptionPlanCore/Sources/TaptionPlanCore/Domain/PlanRecord.swift:33`·`ActualRecord.swift:43`, `TaptionPlan/UI/MapHomeView+Memos.swift:174`(그날 일정)·`:290`(`dayPlans`), `TaptionPlan/UI/LedgerMemoPanel.swift:417`(계획 거르기 규칙), `TaptionPlan/Core/RecordSummaryEngine.swift`(`RecordAnalysisCategoryPolicy`·`DurationText`), `TaptionPlan/Core/ClassifierAdapter.swift:357`(걸음), `TaptionPlan/UI/MapHomeAlarm.swift:160`(`timeText`).
- 이 요청은 「곡선 계산 + 하루 요약 카드」까지입니다. 위젯·워치·공유 카드에 같은 곡선을 넣는 일, 알림(「곧 에너지가 바닥이에요」), AI가 일정을 다시 짜는 일은 다음 요청에서 정합니다.

## 클로드 코드 회신

- 처리: 완료(전체 단위 시험에 이번 변경과 무관한 기존 실패 1건 남음, 아래 참고)
- 요청 ID: ENC1119A01 (`test.md` 홈·UI 줄·요청 상세·실기기 확인 목록·검증 기록)
- 시작·끝: 2026-11-19 19:50 ~ 21:10 (KST)
- 커밋: `40bd53b9` 작업, 문서 이동은 `[비야 브리지] 20261119-1943-energy-curve-visualizer` 한 건. 시작 때 확인한 `origin/main`은 `75abc866`
- 바꾼 파일: `TaptionPlan/Core/EnergyCurveEngine.swift`(새, 255줄), `TaptionPlan/UI/MapHomeEnergyCurveCard.swift`(새, 249줄: 카드·Canvas 그림·`extension MapHomeView`의 `energyCurve(for:)`), `TaptionPlanTests/EnergyCurveTests.swift`(새, 16건), `TaptionPlan/UI/MapHomeInfoSheets.swift`(파라미터 `makeEnergyCurve` 하나와 카드 한 줄), `TaptionPlan/UI/MapHomeView+Presentation.swift`(인자 하나), `TaptionPlan.xcodeproj/project.pbxproj`(새 파일 3개 등록), `test.md`. 동결 파일·`MapHomeView.swift` 본 파일·서버·번역 파일은 건드리지 않음. 파일 이름은 지시서 그대로
- 계약에서 달라진 점: `EnergyCurveResult`에 `day`·`blocks`를 더했습니다(카드가 일정 띠를 그리려면 필요). `EnergyCurveSleep`은 기상 시각을 위해 수면 세션 `span`을 함께 받습니다. 기상 전 칸은 `value: nil`(수면 띠만)입니다. `scheduleStack`은 최저 칸이 있을 때(0.35 미만 여부와 무관) 그 ±90분에 일정 2건 이상이면 붙고, `lowestPoint`는 0.35 미만일 때만 붙습니다
- 검증: 새 `EnergyCurveTests` 16건 통과(지시서 9개 항목 + 보조 7건: 수면 없음·짧은 잠·예측 칸·걸음·분류 매핑·그림 렌더링 연기). Debug 빌드 성공(시험 빌드가 앱 Debug 빌드 포함). 구조 점검 통과, 동결 파일 무변경, 새 파일 모두 1,200줄 미만. 전체 `TaptionPlanTests` 2,963건 실행·건너뜀 26·실패 1(xcresult 통과 3,135) — 실패 1은 이번과 무관한 `AssistantAppControlTests.testAskUserStoresTheQuestionAnswersUploadAndUndoWithdrawsOnlyUnanswered`로, 시험이 질문을 11-12 시각으로 만드는데 보관 기간이 7일이라 오늘부터 만료되는 시간 의존입니다(ANN1119A01 회신에도 적음, 손대지 않음). 시험 실행기 「hung before establishing connection」(0건) 한 번은 시뮬레이터를 껐다 켜 다시 돌림(`hung-app-tests.*` 보관). 지시서가 적은 기존 실패 `TravelModeView` actor 격리·`DayStoreV3Tests` 간헐 실패는 이번 실행에서 나타나지 않았습니다
- 다국어: 새 문구는 전부 `language.text`/`runtimeText` 리터럴. 번역 대기 8문구 × 12개 언어(컨디션 에너지 곡선·이 날은 그릴 기록이 없어요·일정 {0}건·{0} 무렵 가장 낮아요 · 에너지 {1}%·가장 낮은 때 {0} {1}%·그 무렵 일정 {0}건({1})이 겹쳐요·어젯밤 {0} 밤잠이라 시작이 낮아요·어젯밤 수면 기록이 없어 기본값으로 그렸어요). 앞선 ANN1119A01의 4문구와 별개입니다. `unread-report`의 읽지 못한 호출은 155건으로 그대로(내 정적 함수 `text`가 번역 호출로 오인돼 3건 늘었던 것을 `insightLine`으로 바꿔 해결). `generate.py`는 안 돌렸고 `source.json`·`unread-report.json`은 되돌려 둠
- 알아 둘 것: ① 15분 칸 걸음 수는 엔진만 받고 카드는 넘기지 않습니다(하루 표본을 칸마다 다시 훑는 비용이 크고 곡선에 주는 영향이 작음) ② 달력 일정은 분류가 없어 「미확인」으로 쓰므로 예측 곡선에는 영향이 없고 일정 띠·쌓임 인사이트에만 셉니다 ③ 다른 날 요약에서는 달력 일정을 읽지 않고(앱 계획만), 기록은 `currentDayDataSnapshot`이 그날이 아니면 `model.snapshot.actuals`에서 그날과 겹치는 것만 씁니다 ④ 다시 계산 키는 그날·`dayProjectionRevision`·수면 건수·계획 건수입니다. 화면은 눈으로 보지 못했고 그림은 `ImageRenderer` 연기 시험으로만 확인했습니다
- 남은 것·확인 필요: 대표가 `test.md` 실기기 확인 목록의 ENC1119A01 줄을 아이폰 11 Pro로 확인(시뮬레이터 화면도 눈으로는 안 봄). 번역 대기 문구는 메인 세션이 `generate.py`로 처리
