---
id: 20261119-1609-menu-activity-useradded-details
created_at: 2026-11-19T16:09+09:00
status: pending
title: 메인 메뉴 「행동 분류」 펼침 목록에 직접 추가 상세 18개도 표시
from: 비야
basis: 대표 직접 지시 (2026-11-19)
---

## 할 일

1. `git pull --rebase` 뒤 이 문서를 읽고, `AGENTS.md` 2절대로 요청 ID를 새로 만들어 `test.md` `## 남은 작업`(홈·UI 또는 기록·분류·Watch)의 한 줄과 `### 요청 상세`(원인·해결·검증 기준)에 먼저 적습니다. 이 문서에는 `request_id`가 없습니다.
2. 원인(2026-11-19 코드 확인 완료, `origin/main` `0ab5158` 기준):
   - `Packages/TaptionPlanCore/Sources/TaptionPlanCore/Resources/record-classification.json`에 `"userAdded": true`인 상세가 18개 있습니다 — activity 6(멍때리기·친구 만남·데이트·가족·통화·공연/영화 관람), hobby 5(독서·게임·음악·영상 보기·반려동물 돌보기), health 3(회복·투약·명상), housework 4(빨래·장보기·요리·설거지).
   - `TaptionPlan/UI/MapHomeLocationPresentation.swift:141`의 `MapHomeCategoryDetailRows.details(for:)`가 `allDetails(categoryID).filter { $0.userAdded != true }`로 이 18개를 빼고 돌려줍니다.
   - `TaptionPlan/UI/MapHomeView+Menu.swift`의 `categoryMenuItem`이 그 목록만 씁니다 — 펼침 화살표 조건 `if !MapHomeCategoryDetailRows.details(for: category.id).isEmpty`(약 723행)와, 펼쳤을 때 그리는 `MapHomeCategoryDetailRows`(약 767행) 본문의 `ForEach(Self.details(for: categoryID))`.
   - 그래서 메인 메뉴 「행동 분류」를 펼쳐도 네 분류 모두 직접 추가 항목이 한 줄도 안 보입니다(지금도 분류마다 기본 상세가 1개 이상 남아 있어 화살표 자체는 뜹니다. activity 2·hobby 2·health 2·housework 1).
3. 고칠 것 — 메인 메뉴에만 쓰는 표시 목록을 따로 둡니다.
   - `MapHomeCategoryDetailRows`에 `static func menuDetails(for categoryID: String) -> [RecordClassificationDetail] { allDetails(categoryID) }`처럼 `userAdded`를 거르지 않는 목록을 더합니다(`allDetails`를 그대로 열어도 됩니다. 이름은 읽는 쪽이 분명한 것으로).
   - `MapHomeCategoryDetailRows` 본문의 `ForEach`와 `MapHomeView+Menu.swift`의 펼침 화살표 조건을 이 새 목록으로 바꿉니다.
   - **`details(for:)`와 `userAddedDetails(for:)`는 의미를 바꾸지 않습니다.** 기록 수정 화면 `TaptionPlan/UI/MapHomeNLEDetailLane.swift`(약 120~123행)가 기본 목록과 「직접 추가」 구역을 이 둘로 나누고 있고, `TaptionPlanTests/TimeScaleTests.swift`(약 5297~5300행)가 그 나눔을 확인합니다.
4. 표시 규칙: 메인 메뉴에서는 18개를 「직접 추가」 같은 구역 머리 없이 분류표(JSON) 순서 그대로 한 목록으로 보여 줍니다. 항목마다 지금과 같은 화랑이 그림(`MapHomeStickmanGlyph`, `action: MapHomeStickmanActionResolver.action(for: detail.id, label: detail.title)`)과 번역된 이름을 그대로 씁니다. 18개를 따로 표시하지 않는 분기(예: `automaticOnly`로 거르기)를 새로 넣지 않습니다.
5. 시험:
   - `TaptionPlanTests/MapHomeStickmanTests.swift`의 `testCategoryMenuShowsDailyDetailsWithOwnScenes`를 새 메뉴 목록 기준으로 고칩니다. activity·hobby·health·housework의 메뉴 목록 항목 수가 8·7·5·5이고 그 안에 `activity.performanceMovie`·`hobby.reading`·`health.medication`·`housework.dishes`가 들어 있는지, 같은 상세가 두 번 들어가지 않는지, `details(for:)`는 여전히 그 18개를 빼는지 함께 봅니다. `unconfirmed`는 지금처럼 빈 목록이어야 합니다.
   - 18개 전수 시험을 하나 더합니다 — 각 항목의 `MapHomeStickmanActionResolver.action(for: detail.id, label: detail.title)` 기대값과 그 `hwarangScene`. 지금 코드 기준 기대값(빌드에서 다르면 코드가 맞고 이 표를 회신에 정정해 적습니다):

     | 상세 id | 제목 | 기대 동작 | 기대 장면 |
     | --- | --- | --- | --- |
     | activity.zoningOut | 멍때리기 | `.restBox` | `.restBox` |
     | activity.friends | 친구 만남 | `.friends` | `.friends` |
     | activity.date | 데이트 | `.date` | `.date` |
     | activity.family | 가족 | `.family` | `.family` |
     | activity.phoneCall | 통화 | `.phoneCall` | `.phoneCall` |
     | activity.performanceMovie | 공연/영화 관람 | `.performanceMovie` | `.performanceMovie` |
     | hobby.reading | 독서 | `.bookReading` | `.readBook` |
     | hobby.game | 게임 | `.game` | `.game` |
     | hobby.music | 음악 | `.music` | `.music` |
     | hobby.video | 영상 보기 | `.video` | `.video` |
     | hobby.pet | 반려동물 돌보기 | `.petCare` | `.petCare` |
     | health.recovery | 회복 | `.recovery` | `.recoverySuperman` |
     | health.medication | 투약 | `.medication` | `.medicated` |
     | health.meditation | 명상 | `.meditation` | `.meditate` |
     | housework.laundry | 빨래 | `.laundry` | `.laundry` |
     | housework.groceries | 장보기 | `.groceries` | `.groceries` |
     | housework.cooking | 요리 | `.cooking` | `.cook` |
     | housework.dishes | 설거지 | `.dishes` | `.dishes` |

     매핑은 이미 `MapHomeStickmanActionResolver.dailyActions`(제목)에 다 있습니다. 빠지거나 다른 값이 나오는 항목만 그 항목에 한해 보완하고, 보완한 것은 회신에 적습니다.
   - `-only-testing:TaptionPlanTests`로 돌리고, 동작 코드를 바꾸므로 앱 Debug 빌드까지 합니다(`AGENTS.md` 5절 빌드 잠금·로그 경로·시뮬레이터 규칙 그대로). 실제 실행·통과·실패·건너뜀 수치를 xcresult로 확인해 회신에 적습니다.
6. `test.md` `## 실기기 확인 목록`에 기기 확인 줄을 넣습니다 — 「메인 메뉴 › 행동 분류를 펼침 → activity·hobby·health·housework 네 분류에 직접 추가 항목(공연/영화 관람 등)이 모두 보이고 각 줄의 화랑이가 움직임」. 시뮬레이터로 본 화면과 기기 확인을 구분해 적습니다.
7. `pickle-bridge/README.md` 4절 회신 형식대로 `## 클로드 코드 회신`을 적고, frontmatter를 `status: done`·`finished_at`·`commit`으로 채운 뒤 `git mv`로 `pickle-bridge/done/`에 옮겨 커밋·푸시합니다(작업 커밋과 문서 이동 커밋 분리).

## 확인 기준

- 메인 메뉴 「행동 분류」를 펼치면 네 분류 합계 18개의 직접 추가 항목이 모두 보이고, 18개 각각의 화랑이 동작·장면이 시험에서 확인됩니다.
- 기록 수정 화면의 「직접 추가」 구역과 기본 목록 나눔, `TimeScaleTests`의 나눔 확인 줄이 그대로 통과합니다.
- 단위 시험·Debug 빌드 결과가 실제 수치로 적혀 있고, 기기 확인은 따로 표시돼 있습니다.
- 작업 커밋 해시·바꾼 파일·푸시한 브랜치가 회신에 적혀 있습니다.
- 시작할 때 같은 수정이 이미 `main`에 들어가 있으면(메뉴가 `userAdded`를 거르지 않으면) 중복으로 고치지 말고 그 커밋·상태만 회신하고 이 문서를 `done/`으로 옮깁니다.

## 하지 말 것

- `details(for:)`·`userAddedDetails(for:)`의 반환 의미 바꾸기, `MapHomeNLEDetailLane`의 「직접 추가」 구역 손대기. 표시 목록만 새로 더합니다.
- `record-classification.json`의 `userAdded`·`automaticOnly` 값 바꾸기(이 플래그는 자동 판정·기록 수정 화면·일정 제목 규칙이 함께 봅니다). 이번 일은 메인 메뉴 표시 필터 하나입니다.
- `AGENTS.md` 4절 「대표 결정」 바꾸기, 파일 삭제, 서버 배포, TestFlight 업로드, 계정·결제.
- 다른 세션의 미커밋 변경을 이 커밋에 넣기. 작업 폴더에 이미 수정된 파일이 있으면 경로를 지정해 이번에 만진 파일만 커밋합니다.
- 지시서·회신에 개인정보·계정·서버 주소·실제 좌표·실제 동네/가게 이름 쓰기(저장소는 공개입니다, `AGENTS.md` 8절).

## 참고

- `pickle-bridge/README.md`, `AGENTS.md` 5·8·12절.
- 관련 기록: `test.md`의 ICN1119A06(공연/영화 관람 상세분류 추가), CAT1103A02·DTL1111A01(상세 목록과 「직접 추가」 나눔), CAT1105A01(행동 분류 접기·펼치기).
- 이 지시는 새 상세를 더하는 일이 아니라 이미 있는 18개가 메인 메뉴에서 안 보이던 표시 문제를 고치는 일입니다.
