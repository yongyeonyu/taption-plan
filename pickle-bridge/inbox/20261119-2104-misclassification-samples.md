---
id: 20261119-2104-misclassification-samples
created_at: 2026-11-19T21:04+09:00
status: pending
title: 오분류 교정 표본 수집(비식별 특징값)·옵트인·내보내기 기반
from: 비야
basis: 대표 결정(2026-11-17 통화 「활동 분류 — 오분류 로그 수집 & 모델 배포」) · 비야 제안(구현 범위·형식) · 2026-11-19 비야 브리지 배정
---

## 할 일

0. `git pull --rebase` 뒤 이 문서를 읽고, `AGENTS.md` 2절대로 요청 ID를 새로 만들어 `test.md` `## 남은 작업` 중 **기록·분류·Watch**에 한 줄, `### 요청 상세`에 원인(지금 없음)·해결·검증 기준·상태를 먼저 적습니다. 이 문서에는 `request_id`가 없습니다.

1. 지금 상태 (2026-11-19 `origin/main` `011e796`에서 직접 확인함)

   1-1. **중복 없음 확인(했음)** — `git grep -i "misclassif\|분류 개선\|온디바이스"`가 `.swift`에서 0건입니다. 오분류 표본을 모으는 코드도, 옵트인 스위치도, 학습용 내보내기도 아직 없습니다. `Packages/TaptionWatchSync/Sources/TaptionWatchBehaviorML/WatchBehaviorModel.swift`는 워치 전용 선택적 Core ML 모델(없으면 규칙으로 대체)이라 이번 작업과 겹치지 않고, 오히려 「분류기를 나중에 갈아 끼우는 방식」의 선례입니다.

   1-2. **사용자가 분류를 고치는 곳(다섯)** — 전부 `AppModel`의 async 함수이고, predicted(자동) → corrected(사용자)가 그 자리에서 둘 다 보입니다.
   - `TaptionPlan/UX/AppModel+ActualEditing.swift:8` `updateActualActivity(_ actualID:with option:)` — 기록 하나를 교정. `actual`(교정 전)과 `option`이 함께 있습니다.
   - 같은 파일 `:109` `correctActualFragment(_ displayedSpan:startAt:endAt:with option:)` — 겹침으로 갈라진 조각 교정. `option`이 nil이면 시간만 바꾼 것이라 표본이 아닙니다.
   - 같은 파일 `:216` `classifyUnconfirmedSpan(_ span:with option:)` — 「미확인」 구간을 사용자가 분류. predicted는 `unconfirmed`입니다.
   - 같은 파일 `:261` `saveActivitySectionEdit(_ request:)` — 시간표에서 구간을 고치는 주 경로. `ActivitySectionEditRequest`(`TaptionPlan/Core/ActivitySectionOverrideEngine.swift:76`)에 `originalOption`(자동)과 `mode`(`.replace`·`.cutLowerUnconfirmed`·`.insertDetail`·`.cover`)가 있고, 실제 조각은 `ActivitySectionOverrideEngine.pieces(for:)`가 만듭니다.
   - `TaptionPlan/UX/AppModel+MapEditing.swift:205` `confirmTravel(_ travelIDs:mode:)` — 이동 수단 교정. 반복문 안 `wasChanged`가 「정말 바뀌었는지」를 이미 판정합니다. 이 함수만 async가 아니므로 호출 방식이 다릅니다(7절).

   1-3. **특징값을 만들 재료** — 교정 함수들은 센서 원본을 들고 있지 않습니다(`AppModel.snapshot`(`TaptionPlan/UX/AppModel.swift:83`)에는 `actuals`·`travel`·`places`만 있음). 원본은 `AppModel+DayData.swift:520` `func sensorReadings(in span: TimeSpan) async -> [SensorReading]`으로 그 구간만 읽어 옵니다. 걸음은 `ClassifierAdapter.stepCount(readings:in:)`(`TaptionPlan/Core/ClassifierAdapter.swift:357`. 워치가 덮은 시간은 워치 걸음만 셈)를 그대로 씁니다. `SensorReading`에는 `speedMetersPerSecond`·`point?.horizontalAccuracy`·`motion`(`stationary`·`walking`·`running`·`cycling`·`automotive`·`unknown`)·`currentCadenceStepsPerSecond`·`sourceDevice`가 있습니다(`Packages/TaptionPlanCore/Sources/TaptionPlanCore/Domain/SensorReading.swift`).

   1-4. **동의 스위치의 선례** — `TaptionPlan/Core/SharedRuleStore.swift:46`이 「후보 올리기 기본 꺼짐」을 `UserDefaults`에 두고, 화면(`TaptionPlan/UI/SharedRulesView.swift:81` `SharedRulesContributeSection`)에서 안내 문구와 함께 켜게 합니다. 이번 옵트인도 같은 방식을 씁니다(아래 6절). `AppFeatureSettings`(`Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/AppFeatureSettings.swift`)는 예전 저장본과 바이트가 같아야 해서 손대지 않습니다.

   1-5. **곁 파일 선례** — `TaptionPlan/Core/TripShareSidecar.swift:28`·`:58`이 `Application Support/<폴더>`에 `Mutex`로 감싼 작은 파일을 쓰고, 넣는 디렉터리를 주입받아 시험이 임시 폴더로 돌립니다. 이번 JSONL 저장소가 그대로 따를 모양입니다.

   1-6. **규칙 버전** — `ClassificationRules.version`(`TaptionPlan/Core/ClassificationBackfill.swift:10`, 지금 `classifier-v1r4`). 표본마다 이 값을 남겨야 나중에 「어느 규칙이 만든 라벨인지」를 알고 학습에서 뺄 수 있습니다.

2. **새 파일 4개** (이름은 읽는 쪽이 분명하면 바꿔도 되고, 바꿨으면 회신에 적습니다)
   - `TaptionPlan/Core/MisclassificationSample.swift` — 값 타입·특징값 계산(순수)·내보내기 형식. SwiftUI·저장소 타입을 import하지 않습니다.
   - `TaptionPlan/Core/MisclassificationCollector.swift` — 옵트인 판정·JSONL 곁 파일 저장·요약·초기화·내보내기 데이터.
   - `TaptionPlan/UI/MapHomeClassificationDataRow.swift` — 설정 화면에 들어갈 토글·요약·내보내기·지우기.
   - `TaptionPlanTests/MisclassificationCollectorTests.swift` — 단위 시험.
   - 넷 다 `TaptionPlan.xcodeproj/project.pbxproj`에 등록합니다. **등록 방식은 새로 만들지 말고 `EnergyCurveEngine.swift`(`ENC1119A01` 커밋 `40bd53b`)가 들어간 자리를 `git show 40bd53b -- TaptionPlan.xcodeproj/project.pbxproj`로 보고 그대로 따릅니다**(`PBXBuildFile`·`PBXFileReference`·그룹 `children`·target `Sources` 단계). 앱 파일과 시험 파일의 target이 다르니 섞지 않습니다.
   - 각 파일은 1,200줄을 넘기지 않습니다(`architecture-metrics.py --check`가 새 거대 파일로 실패).

3. **표본 한 건의 계약** — 아래 모양을 기준으로 하되 더 나은 이름이 있으면 값 타입 경계를 지키는 선에서 바꿉니다. **핵심 원칙: 이 형식에는 사람이 쓴 글도, 시간의 절대값도, 좌표도 없다.** 저장 형식과 내보내는 형식을 같게 두어 「나가는 파일에만 실수로 날짜가 붙는」 일이 없게 합니다.

   ```swift
   struct MisclassificationSample: Codable, Equatable, Sendable {
       enum Kind: String, Codable, Sendable { case activity, travel }

       var schemaVersion = 1              // 이 형식의 판. 특징 이름이 바뀌면 올린다
       var id: UUID                       // 기기에서 만든 무작위 값. 사람·기기를 가리키지 않는다

       var kind: Kind
       var minuteOfDay: Int               // 0…1439 — 그날 자정부터 분. 날짜는 넣지 않는다
       var weekdayIndex: Int              // 0(일)…6(토)
       var durationSeconds: Int           // 교정한 구간 길이

       var predicted: String              // 자동 분류: 분류표 대분류 코드(예: work·movement·unconfirmed) 또는 TravelMode raw
       var predictedDetail: String?       // 분류표에 있는 behavior 코드만. 없으면 nil
       var predictedConfidence: String?   // low·medium·high (ConfidenceLevel.rawValue)
       var predictedScore: Double?        // 0…1, 0.05 단위. classificationScore가 없으면 nil

       var corrected: String              // 사용자 분류: 분류표 대분류 코드 또는 TravelMode raw. 사용자 지정이면 "custom"
       var correctedDetail: String?       // 분류표에 있는 behavior 코드만
       var correctedIsCustom: Bool        // 사용자가 직접 만든 이름이면 true — 이름 자체는 저장하지 않는다

       var ruleVersion: String            // ClassificationRules.version
       var features: MisclassificationFeatures
   }

   struct MisclassificationFeatures: Codable, Equatable, Sendable {
       var averageSpeedKmh: Double?       // 0.5 단위
       var maximumSpeedKmh: Double?       // 0.5 단위
       var distanceMeters: Double?        // 10m 단위
       var steps: Int?
       var stepCadencePerMinute: Double?  // 1 단위
       var gpsAccuracyMeters: Double?     // 5m 단위(가로 정확도 중앙값)
       var dominantMotion: String?        // stationary·walking·running·cycling·automotive·unknown
       var watchCovered: Bool             // 구간 표본 절반 이상이 워치 표본인가
       var sampleCount: Int               // 그 구간에서 읽은 원본 수(0이면 특징값은 전부 nil)
   }
   ```

   - **넣지 않는 것(시험으로 확인)**: 좌표·경로·주소, 장소·가게·동네·역 이름, `connectedWiFiSSID`, 일정 제목·메모·`title`·`behavior` 원문·`evidence` 문자열, `customActivityLabels`의 글자, 기기 이름·기기 번호, 계정·메일, 절대 날짜·시각(연·월·일·시각 그대로), `fromPlaceKey`·`toPlaceKey`(`TravelModeCorrection`과 `PlaceStay`의 그 값은 개인 장소 열쇠입니다 — `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/MovementModels.swift:300`).
   - `predictedDetail`·`correctedDetail`은 `RecordClassificationCatalog`(분류표)에 있는 `behavior`만 통과시키고, 없으면 nil로 떨어뜨립니다. 사용자 지정 분류는 `corrected: "custom"`·`correctedIsCustom: true`로만 남깁니다.
   - `id`는 `UUID()`. 같은 구간을 다시 고치면 새 표본을 하나 더 넣습니다(맞바꾸기는 하지 않습니다). 중복 제거 열쇠를 날짜로 만들면 그 열쇠 자체가 시각을 담게 되고, 다른 날 같은 시각의 교정이 합쳐져 자료가 사라지기 때문입니다. 연달아 고친 경우 두 번째 표본의 `predicted`가 첫 번째의 `corrected`인 것은 맞는 자료입니다.
   - `MisclassificationFeatureSchema`(같은 파일)에 특징 이름을 **고정 순서 배열**로 둡니다(`featureNames: [String]`). 시험은 표본 하나를 인코딩해 그 이름들이 JSON 열쇠로 모두 있는지, `schemaVersion`이 1인지 봅니다. 이름을 바꾸면 학습 자료와 어긋나므로 바꿀 때 `schemaVersion`을 올린다는 주석을 답니다.

4. **특징값 계산** — `MisclassificationSample.build(...)`(순수 함수) 하나에 모읍니다. `Calendar`는 인자로 받아 시험이 고정 시간대를 넣습니다.
   - `minuteOfDay` = 그 구간 시작의 그날 0시부터 분. `weekdayIndex` = `Calendar.component(.weekday) - 1`.
   - 속도: 구간 안 `speedMetersPerSecond`가 0 이상인 값들의 평균·최대 → km/h로 바꿔 0.5 단위 반올림. 값이 하나도 없으면 nil.
   - 걸음·케이던스: `steps`는 `ClassifierAdapter.stepCount(readings:in:)`(없으면 nil), `stepCadencePerMinute`는 `currentCadenceStepsPerSecond × 60`의 평균을 1 단위로.
   - `distanceMeters`: `TravelSegment.distanceMeters`가 있으면 그 값, 없으면 `walkingRunningDistanceMeters` 증분 합. 10m 단위.
   - `gpsAccuracyMeters`: `point.horizontalAccuracy` 중앙값, 5m 단위.
   - `dominantMotion`: 구간 표본의 `motion` 최빈값(동수면 더 «조용한» 쪽: stationary < walking < running < cycling < automotive 순으로 앞선 것).
   - `watchCovered`: `sourceDevice == .appleWatch` 표본이 절반 이상.
   - 원본이 0건이면 `sampleCount = 0`이고 특징값은 전부 nil입니다. **틀린 특징값을 지어내지 않습니다** — 그날 원본을 못 읽었으면 라벨·시간만 남기고 특징은 비웁니다. 지난 날짜의 구간을 고칠 때도 `sensorReadings(in:)`을 그대로 씁니다(그날 원본이 기기에서 정리됐거나 백업을 아직 복원하지 않았으면 빈 배열이 오고, 그때도 표본은 라벨만으로 남깁니다).

5. **저장소** — `MisclassificationCollector`(클래스 하나, `TripShareSidecar` 방식을 따름)
   - 경로: `Application Support/MisclassificationSamples/samples.jsonl`. 한 줄에 JSON 하나(JSONL, UTF-8, 개행으로 구분). 디렉터리는 주입받습니다(`init(directory: URL, defaults: UserDefaults)`), `static let live`가 실제 경로를 씁니다.
   - `Mutex`로 읽기·쓰기를 감쌉니다. 한 건은 1KB 미만이라 교정이 이미 하는 저장(`persist()`)에 비하면 무시할 수 있는 크기입니다 — 그래서 `Task.detached`를 만들지 않습니다(위험 지표가 늘면 `architecture-metrics.py --check`가 실패합니다).
   - 상한 **5,000건**. 넘으면 오래된 줄부터 버리고 파일을 다시 씁니다(파일 전체를 메모리에 올려도 5MB 미만).
   - `isExcludedFromBackupKey`를 걸어 iCloud 백업에 들어가지 않게 합니다. 스냅숏·백업·동기화 어디에도 넣지 않습니다.
   - 깨진 줄은 그 줄만 건너뛰고 나머지를 읽습니다(앱이 멈추지 않게).
   - 메서드: `isEnabled`·`setEnabled(_:)`·`capture(...) -> MisclassificationSample?`·`samples(limit:)`·`summary()`·`removeAll()`·`exportPayload() -> Data`.
   - `summary()`는 `struct Summary { var total: Int; var activity: Int; var travel: Int; var topCorrected: [(code: String, count: Int)] }`(많은 순 5개)입니다. 날짜·시각은 세지 않습니다.
   - `removeAll()`은 파일을 지우고 다음 `capture` 때 다시 만듭니다. `AppModel.deleteAllUserData`(`TaptionPlan/UX/AppModel+Backup.swift:253`)에서 `MapHomeRangeSampleCache.removeAll()` 옆에 `MisclassificationCollector.live.removeAll()`을 한 줄 더합니다.
   - 삭제가 도는 중(`isDeletingUserData`)에는 `capture`가 아무것도 쓰지 않습니다.

6. **옵트인(기본 꺼짐)** — `UserDefaults` 열쇠 `misclassificationCollectionEnabled`, 기본값 false(`defaults.bool(forKey:)`는 없으면 false라 따로 `object(forKey:)`를 쓰지 않아도 됩니다). `SharedRuleStore.contributeKey`와 같은 자리에 두고, `defaults`를 인자로 받아 시험이 전용 suite를 씁니다.
   - **판정은 `capture` 안에서 한 번** 합니다(호출부마다 검사하지 않습니다). 꺼져 있으면 아무 파일도 만들지 않고 nil을 돌려줍니다.
   - 켜고 끄는 화면은 7절의 설정 행 하나뿐이고, 끄면 이미 모은 것도 함께 지울지 묻습니다(「끄면 더 모으지 않아요. 이미 모은 N건은 그대로 두고, 지우려면 「지우기」를 누르세요.」). 임의로 지우지 않습니다.

7. **연결(동작 코드는 다섯 곳 + 한 곳)**
   - `AppModel`에 감싸는 함수 하나를 둡니다(같은 파일 `AppModel+ActualEditing.swift` 맨 아래, 40줄 이내).
     ```swift
     private func captureMisclassification(
         kind: MisclassificationSample.Kind,
         span: TimeSpan,
         predicted: String, predictedDetail: String?,
         predictedConfidence: String?, predictedScore: Double?,
         corrected: String, correctedDetail: String?, correctedIsCustom: Bool
     ) {
         let collector = MisclassificationCollector.live
         guard collector.isEnabled, !isDeletingUserData else { return }
         Task { [span] in
             let readings = await sensorReadings(in: span)
             collector.capture(kind: kind, span: span, readings: readings,
                               predicted: predicted, predictedDetail: predictedDetail,
                               predictedConfidence: predictedConfidence, predictedScore: predictedScore,
                               corrected: corrected, correctedDetail: correctedDetail,
                               correctedIsCustom: correctedIsCustom,
                               calendar: .autoupdatingCurrent)
         }
     }
     ```
     `sensorReadings(in:)`은 async라서 Task 안에서 부릅니다. `Task {}`는 그대로 두고 `Task.detached`는 쓰지 않습니다.
   - 호출 지점(각 한 줄, **정말 바뀐 경우에만**):
     1. `updateActualActivity` — 저장이 끝난 뒤, `actual`(교정 전)의 `categoryID`·`behavior`·`confidence`·`classificationScore`와 `option`을 넘깁니다. `option.categoryID == actual.categoryID && option.behavior == actual.behavior`면 부르지 않습니다.
     2. `correctActualFragment` — `option`이 있을 때만. `span`은 고친 구간(`startAt`~`endAt`)이고 predicted는 `actual`에서.
     3. `classifyUnconfirmedSpan` — predicted는 `"unconfirmed"`·detail nil·확신도 nil.
     4. `saveActivitySectionEdit` — `ActivitySectionOverrideEngine.pieces(for: request)`를 보고 **`originalOption`과 다른 조각이 정확히 하나일 때만** 그 조각의 `span`·`option`으로 부릅니다. 여러 조각을 한꺼번에 다른 분류로 덮은 경우(`.cover`에 서로 다른 옵션)는 한 줄짜리 표본으로 담을 수 없으니 넣지 않습니다(그 사실을 주석 한 줄로 남깁니다).
     5. `confirmTravel` — 반복문 안에서 `wasChanged`가 true인 구간마다. predicted는 바꾸기 전 `snapshot.travel[index].mode`·`confidence`, corrected는 `mode`. 사용자 지정 이름이 없으므로 `correctedIsCustom = false`.
   - 호출은 모두 저장이 성공한 뒤에 합니다. 교정이 저장에 실패한 경우(예: `saveActivitySectionEdit`의 rollback 경로)에는 표본을 남기지 않습니다.
   - 자동 재계산(`ActivityClassificationLockEngine`)·AI 명령(`AssistantCommandEdits`)처럼 사람이 화면에서 고친 것이 아닌 경로는 **이번에 넣지 않습니다**. 「사용자가 손으로 고쳤다」만 이 자료의 라벨로 칩니다(넣을지는 다음 판단).

8. **설정 화면** — `TaptionPlan/UI/MapHomeSettingsSheets.swift:401`의 `card(language.text("내 데이터", "My data"))` 안, `MapHomeDataControlsRow` 다음에 `MapHomeClassificationDataRow(model: model, language: language)` 한 줄을 더합니다(기존 파일에 더하는 것은 이 한 줄).
   - 새 파일 `MapHomeClassificationDataRow`의 모양:
     - `Toggle(language.text("분류 개선 데이터 수집", "Collect classification improvement data"), isOn: …)` 기본 꺼짐. `.tint(Color.tpReferenceMint)`.
     - 안내 문구(작은 글씨, 리터럴): 「켜면 분류를 고칠 때마다 **시간대·길이·평균 속도·걸음 수·바꾸기 전 분류 → 바꾼 분류·확신도**만 기기에 쌓아요. 좌표·장소 이름·일정 제목·날짜는 넣지 않아요. 자동으로 보내지 않고, 「내보내기」를 누를 때만 파일로 나가요.」
     - 그 아래 「기기에 N건 모음」(`summary()` 값)과 「내보내기」·「지우기」 단추. 「지우기」는 `confirmationDialog`로 한 번 묻습니다(되돌릴 수 없음).
     - 「내보내기」는 `exportPayload()`를 임시 폴더 `misclassification-samples.json`에 쓰고 기존 `MapHomeDataControlsRow`가 쓰는 방식(공유 시트)으로 넘긴 뒤 파일을 지웁니다. 그 파일에는 3절의 표본만 들어갑니다.
     - 값은 `@State` + `.task`로 한 번 읽고, 토글·지우기 뒤에 다시 읽습니다. `body`에서 매번 파일을 읽지 않습니다(`AGENTS.md` 3절).
   - **네트워크 전송 코드는 이번에 넣지 않습니다.** 「전송 준비」는 9절의 내보내기 형식까지입니다.

9. **나중에 서버로 보낼 때의 형식(이번엔 서버를 만들지 않음)** — `exportPayload()`가 만드는 JSON을 그대로 `POST /classifier-samples`의 본문으로 쓸 수 있게 둡니다. 코드 주석에만 적고 문서 파일은 새로 만들지 않습니다.

   ```json
   {"format":"bokki-misclassification","version":1,"ruleVersion":"classifier-v1r4","samples":[ … 3절 표본 … ]}
   ```
   - 다음 요청(대표 결정)에서 정할 것: `POST /classifier-samples`(주인 키, 200건·1MB까지, `id`가 같으면 무시), `GET /classifier-samples?since=`, D1 표 `misclass_samples`, 보관 기간. **이번 커밋에 `server/trip-relay`를 건드리지 않습니다.**

10. **문서** — `PRIVACY.md` 「저장과 외부 전송」에 한 줄을 더합니다(초안, 대표 확정 전 문단과 같은 결): 「설정에서 「분류 개선 데이터 수집」을 켠 경우에만, 분류를 고칠 때마다 시간대·길이·평균 속도·걸음 수·바꾸기 전 분류와 바꾼 분류·확신도·규칙 버전을 좌표·장소 이름·일정 제목·날짜 없이 기기에 저장합니다. 자동으로 보내지 않으며, 사용자가 「내보내기」로 직접 내보낼 때만 기기 밖으로 나갑니다. 「모든 데이터 삭제」에서 함께 지워집니다.」 `DEVELOPMENT.md`의 「프로젝트 경계」 표에서 「분류 알고리즘(분류표 v4·키워드·창 특징·…)」 줄 아래에 `TaptionPlan/Core/MisclassificationSample.swift`·`MisclassificationCollector.swift`(오분류 교정 표본·옵트인·내보내기) 한 줄을 더합니다. `README`·`docs/NEXT_PLAN.md`는 건드리지 않습니다.

11. **단위 시험** — `TaptionPlanTests/MisclassificationCollectorTests.swift`(XCTest, `@testable import TaptionPlan`, `import TaptionPlanCore`, 가짜 좌표·가짜 이름만, 임시 폴더·전용 `UserDefaults(suiteName:)`).
    1. **기본값 OFF**: 꺼진 채 `capture`를 불러도 파일이 생기지 않고 `summary().total == 0`이며 반환값이 nil.
    2. **켜면 한 건**: 켜고 부르면 `total == 1`, `samples()`가 한 건, `kind`·`predicted`·`corrected`·`minuteOfDay`·`durationSeconds`가 넘긴 값과 같다.
    3. **개인정보·좌표 미포함**: 좌표(`37.5…`)·가게 이름·일정 제목·`evidence` 문자열이 섞인 `SensorReading`·`ActualRecord`로 표본을 만들고, 인코딩한 JSON 문자열에 그 값들이 하나도 없고 좌표 숫자가 없음을 확인. JSON 열쇠 집합이 3절 목록과 정확히 같다(모르는 열쇠가 늘면 실패).
    4. **사용자 지정 분류**: 이름이 「나만의 취미」인 `ActivityCorrectionOption(isCustom: true)`으로 만들면 `corrected == "custom"`·`correctedIsCustom == true`이고 그 글자가 JSON에 없다.
    5. **특징값 없음**: 원본 0건이면 `sampleCount == 0`이고 `features`의 수치가 모두 nil(0으로 채우지 않음).
    6. **직렬화·파싱**: 표본 3건을 append → 다시 읽어 `Equatable`로 같다. 파일에 깨진 줄을 하나 끼워 넣어도 나머지 3건을 읽는다.
    7. **상한**: 5,000건을 넘겨 넣으면 5,000건이고 가장 오래된 줄이 사라진다(상한을 시험에서 낮춰 주입할 수 있게 `maximumSamples` 인자를 둡니다).
    8. **초기화**: `removeAll()` 뒤 `total == 0`이고 파일이 없다. 다시 `capture`하면 새로 만들어진다.
    9. **요약**: kind별 건수와 `topCorrected`가 많은 순 5개까지만 나온다.
    10. **내보내기**: `exportPayload()`가 `format`·`version`·`ruleVersion`·`samples`를 갖고, `samples` 수가 `summary().total`과 같다. 날짜(연월일) 문자열이 들어 있지 않다.
    11. **시각 경계**: 자정을 넘긴 구간은 `minuteOfDay`가 그날 자정 기준이고 `durationSeconds`가 잘리지 않는다(구간 길이 그대로). 다른 시간대(`America/New_York`)에서도 `minuteOfDay`가 0…1439.
    12. **바뀌지 않은 교정**: 같은 분류를 다시 고른 경우 표본을 만들지 않는다(5절의 호출부 규칙을 함수로 뽑아 시험).

12. **검증**
    - `AGENTS.md` 5절 빌드 잠금(`/tmp/taptionplan-xcodebuild.lock`, `owner`에 「요청ID pid」) 안에서: 앱 Debug 빌드 → `-only-testing:TaptionPlanTests/MisclassificationCollectorTests` → `-only-testing:TaptionPlanTests`(시뮬레이터 `99AC6F35-6B50-4741-A11D-1A46E1F7F4BD`, `-parallel-testing-enabled NO`). 실행·통과·실패·건너뜀 수치는 xcresult로 읽어 회신에 적습니다.
    - 이미 실패 중인 항목(`TravelModeView` actor 격리, `DayStoreV3Tests` 간헐 실패)은 이번 변경과 섞지 말고 **따로** 적습니다. 새로 깨진 시험이 있으면 그것부터 고칩니다.
    - 교정 경로를 건드리므로 `FeatureEngineTests+Classification`·`AssistantReviewFixTests`처럼 사용자 교정을 다루는 시험이 함께 통과하는지 봅니다. 표본 저장은 기본값이 꺼져 있어 기존 시험이 파일을 만들지 않아야 합니다(만들면 그 자체가 결함).
    - `python3 scripts/architecture-metrics.py --check docs/architecture-baseline.json` 통과. `docs/architecture-baseline.json`은 바꾸지 않습니다. `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable`을 늘리지 않습니다(늘면 실패).

13. **문구·번역** — 새 문구는 전부 `language.text("한국어", "English")` 리터럴로 씁니다. `UIText.xcstrings`·`Localizable`을 손으로 고치지 않고, `python3 scripts/l10n/extract.py`로 새 키가 `scripts/l10n/source.json`에 들어가고 `unread-report.json`에 읽지 못한 호출이 없는지 확인한 뒤 `python3 scripts/l10n/check.py`를 돌립니다. 12개 언어의 새 문구 누락은 **「번역 대기」로 회신에 목록만 적습니다**(`generate.py`는 메인 세션 몫이라 돌리지 않습니다).

14. `test.md` `## 실기기 확인 목록`에 아이폰 11 Pro 줄을 넣습니다 — 「설정 › 내 데이터 › 분류 개선 데이터 수집: ① 꺼진 채 시간표에서 분류를 한 번 고쳐도 「0건」 ② 켜고 한 번 고치면 「1건」 ③ 「내보내기」 파일을 열어 좌표·장소 이름·연월일이 없고 「바꾸기 전 → 바꾼」 분류가 보이는지 ④ 「지우기」 뒤 「0건」」. 시뮬레이터로 본 화면과 기기 확인을 구분해 적습니다.

15. `pickle-bridge/README.md` 4절 회신 형식대로 `## 클로드 코드 회신`을 적고, frontmatter를 `status: done`·`finished_at`·`commit`으로 채운 뒤 `git mv`로 `pickle-bridge/done/`에 옮겨 커밋·푸시합니다(작업 커밋과 문서 이동 커밋 분리, 경로를 지정해 커밋).

## 확인 기준

- 분류를 실제로 고쳤을 때만 표본이 한 건 늘고, 같은 분류를 다시 고르거나 시간만 바꾼 경우에는 늘지 않는다.
- 표본에는 좌표·장소/가게/동네/역 이름·일정 제목·메모·사용자 지정 분류 이름·`evidence` 글자·절대 날짜가 없다(인코딩한 JSON으로 확인).
- 옵트인이 기본 꺼짐이고, 꺼져 있으면 파일조차 생기지 않는다. 켜고 끄는 곳은 설정 › 내 데이터 한 곳뿐이다.
- 원본을 못 읽은 구간은 특징값을 지어내지 않고 비운 채 라벨·시간만 남긴다.
- 「모든 데이터 삭제」가 표본 파일도 지운다. 표본은 iCloud 백업·스냅숏에 들어가지 않는다.
- 요약 조회·초기화·내보내기가 동작하고, 내보내기 형식이 9절의 `POST /classifier-samples` 본문과 같다.
- 새 시험이 11절 항목을 모두 덮고, 실제 실행된 수치가 회신에 있다. 앱 Debug 빌드와 `-only-testing:TaptionPlanTests` 결과가 xcresult 수치로 적혀 있고 기존 실패 항목과 구분돼 있다.
- `architecture-metrics.py --check` 통과, 동결 파일 5개 무변경, `server/trip-relay` 무변경, 새 파일이 각각 1,200줄 미만.
- 새 문구가 `language.text` 리터럴이고 12개 언어 누락은 「번역 대기」로만 보고돼 있다.
- 작업 커밋 해시·바꾼 파일·푸시 상태가 회신에 적혀 있다.

## 하지 말 것

- **`server/trip-relay` 수정·서버 배포·D1/R2 쓰기·`wrangler`** — 이번 요청은 앱 안에서 끝납니다. 네트워크 전송 코드(URLSession·중계 호출)도 넣지 않습니다.
- 자동 업로드·오프라인 전송 큐·재시도 — 사용자가 「내보내기」를 누르지 않으면 기기 밖으로 아무것도 나가지 않습니다.
- 동결 파일 5개 수정 — `docs/architecture-baseline.json`의 `frozen_files`: `TaptionPlan/Core/HealthKitImportCoordinator.swift`, `TaptionPlan/UI/AppShellView.swift`, `TaptionPlan/UI/MapHomeNLEClipEditor.swift`, `TaptionPlan/UI/MapHomeTimeSidebar.swift`, `TaptionPlan/UI/MapHomeVectorMap.swift`.
- `MapHomeView.swift`(본 파일)에 `@State`·저장 속성 더하기. 새 상태는 새 파일이 듭니다.
- `AppFeatureSettings` 스키마·Codable 변경(예전 저장본과 바이트가 같아야 함). 동의는 `UserDefaults`, 표본은 곁 파일입니다.
- `TaptionPlan` 저장소(SQLite) 스키마·백업 형식·iCloud 동기화에 표본 넣기.
- 분류 파이프라인의 판정 자체 바꾸기(`ClassifierAdapter`·`TaptionClassifierEngine`·`ClassificationRules.version`·확신도 계산). 이번 작업은 **관찰만** 합니다. `ruleVersion`은 읽기만 합니다.
- `import CoreML`·`Core ML` 모델 동봉·모델 다운로드. 이번엔 자료만 모읍니다.
- HealthKit 권한 확대, 새 센서 수집, 새 위치 권한.
- `try!`·`Task.detached`·`fatalError`·`nonisolated(unsafe)`·`@unchecked Sendable` 추가(위험 지표가 늘면 `--check`가 실패).
- `UIText.xcstrings`·`Localizable`·`translations/*.json` 손으로 고치기, `generate.py` 돌리기.
- 사용자 지정 분류 이름·일정 제목·메모·장소 이름을 시험이나 표본에 넣기. 시험은 가짜 값만 씁니다(저장소는 공개입니다 — `AGENTS.md` 3·8절).
- 다른 세션의 미커밋 변경(예: `TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg`)을 이번 커밋에 넣기. 경로를 지정해 이번에 만진 파일만 커밋합니다.

## 참고

- `pickle-bridge/README.md`, `AGENTS.md` 2·3·4·5·8·12절, `DEVELOPMENT.md` 「검증 명령」.
- 바탕 결정: `notes` 없이 저장소 기록 기준 — `docs/ACCURACY_PLAN.md`(분류가 틀리는 이유 10가지·제안 A~D, 특히 「사용자 교정이 기록 번호에 묶여 경계가 움직이면 떨어진다」는 10번), `test.md` 「기록·분류·Watch」의 `ACC1114A01`·`PAY1114A01` 줄.
- 교정 경로: `TaptionPlan/UX/AppModel+ActualEditing.swift`(8·109·216·261), `TaptionPlan/UX/AppModel+MapEditing.swift:205`, `TaptionPlan/Core/ActivitySectionOverrideEngine.swift:76`(`ActivitySectionEditRequest`), `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/ActivityCorrectionModels.swift`(`ActivityCorrectionOption.isCustom`).
- 자료: `TaptionPlan/UX/AppModel+DayData.swift:520`(`sensorReadings(in:)`), `TaptionPlan/Core/ClassifierAdapter.swift:357`(`stepCount`), `Packages/TaptionPlanCore/Sources/TaptionPlanCore/Domain/SensorReading.swift`·`TravelSegment.swift`·`ActualRecord.swift`(`ConfidenceLevel`), `TaptionPlan/Core/ClassificationBackfill.swift:10`(`ClassificationRules.version`), `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/MovementModels.swift:300`(`TravelModeCorrection` — `fromPlaceKey`·`toPlaceKey`는 절대 옮겨 적지 않음).
- 선례: `TaptionPlan/Core/TripShareSidecar.swift`(곁 파일·`Mutex`·주입 디렉터리·백업 제외), `TaptionPlan/Core/SharedRuleStore.swift:46`·`TaptionPlan/UI/SharedRulesView.swift:81`(옵트인 `UserDefaults`·기본 꺼짐·안내 문구), `Packages/TaptionWatchSync/Sources/TaptionWatchBehaviorML/WatchBehaviorModel.swift`(나중에 분류기를 Core ML로 갈아 끼울 때의 모양: 모델이 없으면 규칙으로).
- 서버 규격 선례: `docs/ACTIVITY_RELAY_API.md` 2절(경로·인증·한도 표). 다음 요청에서 `POST /classifier-samples`를 넣을 때 이 표에 한 줄을 더하는 방식.
- 이 요청은 「앱에서 표본을 모아 두고 사용자가 내보내는 데까지」입니다. 서버 엔드포인트·D1 표·맥 학습 스크립트(Core ML 변환·R2 배포)·앱이 모델을 내려받아 교체하는 일은 다음 요청에서 정합니다.
