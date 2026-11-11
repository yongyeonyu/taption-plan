# Taption Trip → BOKKI Plan 이식 분석 (TRP1111A01)

2026-11-11. 읽기만 한 분석이다. 코드는 바꾸지 않았다.
- Taption Trip: `~/Documents/Taption WBS`. 브랜치는 `redesign/v2-pro-siri`이고 커밋 안 된 파일이 30개 있다. 줄 번호는 이 디스크 상태 기준이다.
- BOKKI Plan: 이 저장소 `main`. 작업 트리에 가계부 파일 변경이 있다.

이식할 때는 Trip 쪽 기준 커밋을 먼저 정한다. 커밋 안 된 30개 파일을 함께 쓸지도 결정해야 한다.

## 1. 한눈에

| 영역 | BOKKI Plan에 이미 있음 | Taption Trip이 더 가진 것 | 판단 |
|---|---|---|---|
| 여행 장부 | 예산 이체, 끝난 뒤 반납·추가 경비, 동행, 결제자 | 지갑(통화별 잔액), 환전·출금 기록 | 지갑은 결정 필요 |
| 나누기 | 나만 / 다 같이 / 골라서. 모두 똑같이 나눔 | 금액·퍼센트 나누기와 검증 | **가져옴** |
| 공금 | 없음. "따로 두지 않는다"는 대표 결정(`LedgerTrips.swift:79`) | 각출, 지출마다 공금 %, 공금 초과 사용 경고 | **결정 필요** |
| 환불 | 함께 쓴 지출의 환불도 내 수입으로만 잡힘 | 원 지출에 연결, 같은 사람들에게 되나눔, 과다 환불 검사 | **가져옴** (PROPOSALS 8-4와 함께) |
| 송금 계산 | 탐욕법, 송금마다 반올림, 나머지 원 배분 없음 | 최대 잔여법 반올림, 4~12명은 비트마스크 DP로 송금 수 최소화 | **가져옴** (1순위) |
| 환율 | 중계 서버 `/fx`(ECB 기준값)와 수동 값. 저장할 때 원화로 고정 | 행마다 환율 스냅샷, 가중평균 지갑 원가, 은행 "현찰 살 때" 스크래핑 | 스냅샷만 참고. 스크래핑은 안 가져옴 |
| 정산 공유 | 화면, xlsx, CSV, PNG | 송금 체크(보냄 표시), 카톡용 글, 정산표 PNG 카드 | **가져옴** |
| 영수증 배분 | OCR로 합계만 읽음 | 카드 실제 청구액과 쿠폰을 비율로 나눔 | 나중에 |
| 이동 시간 | 직선거리 추정. 가져오기 미리보기에만 있고 저장 안 함 | MKDirections ETA, 여유 판정, 캐시, 요청 제한 | **가져옴** (계획 쪽 1순위) |
| 계획·실제 정렬, 숙소 자동 추가 | BOKKI 본업(센서 자동 기록)이 이미 더 깊다 | GPS·수면 기반 정렬 엔진 | 안 가져옴. 규칙만 참고 |
| 타임라인·일정 UI | 자체 타임라인 있음 | 240Hz UIKit 캔버스, 플랜 A/B/C, 연결선 | 안 가져옴. 플랜 B만 아이디어 |
| 지도 | MapKit과 MapLibre(백자 지도) | MapKit, MapLibre와 OpenFreeMap | 안 가져옴 |
| Siri·음성 | 지출 기록, 영수증 넣기, 결제 문자 단축어 | 온디바이스 음성 → 한국어 지출 파서(`TaptionVoice`), "방금 거 취소" | 파서만 후보 |
| 예산 Live Activity | Live Activity 있음(다른 용도) | 지표 18종 여행 예산 표시 | 나중에 |
| 저장 | SQLite 정본 | `.xlsx` 정본, `TripStore` | 안 가져옴 |
| 유료 권한 | IAP 보류 중(AGENTS.md) | StoreKit Pro | 안 가져옴 |

## 2. BOKKI Plan에서 지금 고칠 만한 정산 결함

Trip이 이미 해결한 문제들이다. 이식 단위를 고르는 근거가 된다. 모두 코드에서 확인했다.

1. **환율이 없으면 0원으로 계산된다.** `amountKRW == nil`이면 정산과 합계에서 0이 된다(`LedgerTrips.swift:92`, `LedgerCore.swift` `signedKRW`). Trip은 이런 지출을 "환율 없음" 목록으로 따로 알린다.
2. **동행을 늦게 추가하면 지난 지출이 다시 나뉜다.** `shareNames == nil`인 "다 같이" 지출을 지금 동행 목록으로 나누기 때문이다(`LedgerTrips.swift:103`). Trip은 동행 목록을 바꾸기 전에 그때의 참여자를 고정한다(`snapshotImplicitExpenseParticipants`, TripDomain:1956).
3. **함께 쓴 지출의 환불이 내 수입이 된다.** 여행 수입 분기(`LedgerTrips.swift:93-101`). 4명이 낸 숙소비를 환불받으면 나 혼자 받은 돈으로 잡힌다.
4. **송금 금액 반올림이 지출 합계와 어긋날 수 있다.**
   - 몫을 `amount / n` 소수로 두고 송금마다 `.rounded()`를 한다(`LedgerTrips.swift:126`).
   - 처음 정렬한 순서로만 짝을 지어 송금 수가 최소가 아니다.
   - 일상 정산 `LedgerSettlement`은 Dictionary 순서를 따라 같은 금액일 때 결과가 매번 달라질 수 있다.
5. **형식이 안 맞는 기록이 조용히 사라진다.**
   - `LedgerBook.read`가 `compactMap { try? decode }`로 읽는다(`LedgerCore.swift:224-227`).
   - 디코더를 직접 쓰지 않아, Optional이 아닌 칸(`currency`, `kind`, `source`, `createdAt`, `LedgerTrip.members`)의 키가 빠지면 그 행이 통째로 빠진다.
   - 모르는 enum 값이 든 행은 옛 빌드에서 사라진다.
   - **새 필드를 넣기 전에 반드시 먼저 막아야 한다.**
6. **여행 중에도 일상 장부로 들어간다.** 단축어·Siri·AI·메모로 들어온 지출에는 `tripID`가 붙지 않는다. 붙는 곳은 `LedgerSheet` fill과 `LedgerTripView`뿐이다. Trip의 기능은 아니고 BOKKI 자체 보강이다.

## 3. 이식 단위 (하나씩 떼어 가져올 순서)

각 단위는 따로 요청 ID를 만들어 진행한다. 위 단계가 아래 단계의 선행 조건이다.

### U1. 정산 반올림과 최소 송금 — 데이터 변경 없음 (끝: STL1111A01, `LedgerSplit`)
- **가져올 것**
  - `TripSettlementEngine.minimalTransfers`(TripSettlement.swift:802-913): 탐욕법을 기본으로 하고, 4~12명이면 합이 0인 묶음을 비트마스크 DP로 찾는다. 송금 수가 줄 때만 채택한다.
  - `roundedShares` 최대 잔여법(:256)과 `aggregateRoundedExpenses`(:199).
- **바꿀 곳**
  - `LedgerTripMath.sheet`와 `transfers`(`LedgerTrips.swift:81-133`).
  - `LedgerSettlement`(`LedgerCore.swift:139-172`): 정렬 순서를 결정적으로.
- **맞춤**: Trip은 동행 ID가 `UUID`이고 BOKKI는 이름 `String`이다. 알고리즘은 키 타입에 무관하게 제네릭으로 옮긴다. 원화는 소수 자릿수가 0이다.
- **시험**: TripSettlementChecksTests `testExactSearchUsesFewerTransfers…`, `testGreedyResultIsKept…`, `testMoreThanTwelve…`, 무작위 속성 테스트 2개, TripSettlementTests `testNetBalancesAlwaysSumToZero`, `testAggregateRoundingPreservesKRWTotal…`, `testRemainderIsAbsorbedByThePayer`. 기존 `LedgerTests` 431·450행도 통과해야 한다.
- **난이도**: 하. 저장 형식과 백업에 영향 없음.

### U2. 가계부 디코드 안전망 — 모든 데이터 변경의 선행 조건
- `LedgerEntry`·`LedgerTrip`·`LedgerBudget`에 디코더를 직접 쓴다. Optional이 아닌 칸은 `decodeIfPresent ?? 기본값`으로 읽는다.
- 앞으로 더할 열거값은 모르는 값이면 `.other` 같은 대체값으로 받는다.
- 읽기 실패 건수를 세어 로그로 남긴다. 조용히 빠지지 않게 한다.
- 옛 JSON(현재 빌드 316이 쓰는 모양)을 고정 자료로 넣어 읽는 시험과, 키가 빠진 JSON 시험을 더한다.
- 저장 스키마, 백업 TAPTBK03/02 형식은 그대로다. body JSON만 늘어난다.

### U3. 참여자 고정 (결함 2)
- 동행 목록을 바꾸기 직전에 그 여행의 `shareNames == nil` 지출을 그때 `everyone`으로 채운다(Trip `snapshotImplicitExpenseParticipants`와 같은 방식).
- 이미 있는 칸을 채우기만 하므로 옛 빌드에서도 읽힌다.

### U4. 나누기 방식(금액·퍼센트)
- **가져올 것**
  - `ExpenseSplitMode`(even/amount/percent, TripDomain:317)
  - `validatedCustomShares`(:547-574): 참여자 전원에게 값이 있어야 하고, 허용 오차는 퍼센트 ±0.005, 금액은 최소 단위의 절반
  - `shares`(TripSettlement:692-749): 금액 합이 총액을 넘으면 비율대로 줄이고, 나머지는 결제자가 참여자면 결제자에게
- **BOKKI 필드**(Optional로 더함): `splitMode: String?`(nil이면 지금처럼 똑같이), `shareWeights: [String: Double]?`(이름 → 금액 또는 %).
- **화면**: `LedgerShareSection`(`LedgerTripView.swift:184-232`). Trip의 `ExpenseSplitEditor`(EditingSheets:4738)는 참고만 하고 BOKKI 디자인으로 새로 만든다.
- **영향**
  - xlsx·CSV: 열을 늘리지 않고 `LedgerSummary.splitText` 비고에 적는다.
  - AI: `addExpense`/`updateExpense`에 나누기를 열지는 PROPOSALS §4(T1·T2)의 결정을 따른다. 연다면 앱 파서와 서버 `validate.js`·`mcp.js`를 함께 고치고 배포한다.
- **시험**: TripSettlementTests의 even/subset/fixed/percent 시나리오, `testMissingCustomShareIsReported…`, `testDuplicateCaseCustomShareKeysAreReported…`.

### U5. 환불 연결 (결함 3)
- **가져올 것**: `refundOfEntryID`와 `isValidRefund`(TripDomain:2229-2253).
  - 금액이 0보다 크다.
  - 같은 통화다.
  - 환불 시각이 원 지출 시각 이후다.
  - 누적 환불이 원 지출 금액 이하다.
  - 환불은 원 지출 당시 환율로 환산한다(:2268).
  - 정산에서는 원 지출의 결제자·참여자·나누기 방식으로 순액(원 지출 − 환불)을 나눈다.
- **BOKKI 필드**: `refundOf: UUID?`.
- **겹침**: PROPOSALS 8-4(카드 취소 문자를 원 기록에 연결, A안 결정 대기)와 같은 필드를 쓴다. 대표 결정 뒤 한 번에 한다.
- **시험**: `testPartialRefundReducesDirectPayment…`, `testFullRefundRemoves…`, `testRefundPreservesSubsetParticipants`, `testOverRefund…`, `testOrphanRefund…`, `testCurrencyMismatchRefund…`.

### U6. 환율 없음 경고 (결함 1)
- Trip의 `UnpricedSettlementExpense`처럼 정산 화면에 "환율을 몰라 빠진 지출 N건"을 보여 준다.
- 고치는 길: 수동 환율을 넣거나 다시 받기.
- 데이터 변경 없음.

### U7. 송금 체크·공유 글·정산표 카드
- **가져올 것**
  - `SettlementCheck`(from/to, 통화, `amountMinorUnits`, doneAt): 다시 계산한 금액이 체크할 때와 다르면 "금액 바뀜"으로 표시한다.
  - `SettlementShareText`: 카톡용 글과 송금 요청 문장, 을/를 조사 처리.
  - `SettlementShareCard`(PNG, 193줄).
- **BOKKI 저장**: `LedgerTrip.checks: [Check]?`(Optional).
- **바꿀 것**: "BOKKI Trip에서 계산했어요." 하드코딩 문구(TripSettlementChecks:150)를 BOKKI Plan 문구와 12개 언어 팩으로 바꾼다.

### U8. 계획 이동 시간 (TravelEstimateService)
- **가져올 것**: `TravelEstimateService`(839줄, MKDirections만 사용).
  - 캐시 키: 좌표 1e-4°, 이동수단, 15분 단위
  - 유효기간: 도보 7일, 차량 12시간, 실패 5분
  - 요청 제한: 동시 4건, 분당 30건, throttled면 3분 쉼, 오프라인이면 2분 쉼
  - 여유 판정: 남는 시간 − ETA가 0 미만이면 부족, 10분 이하면 빠듯
- **BOKKI 연결**
  - 지금은 `TripImportTimingCheck`(직선거리, `TripImportModel.swift:248-280`)만 있다.
  - 저장된 `TravelTripItem`에는 이동 수단과 분이 남지 않는다. 가져오기 JSON의 `travelFromPrevious`는 미리보기에서 버려진다.
  - 이동 수단을 저장하려면 `AppFeatureSettings` 스냅샷 호환 확인이 필요하다.
- **지도 규칙**: ETA 캐시는 파생값이라 지도 캐시 규칙(bounded, 축출)을 따른다. Apple 지도 타일은 저장하지 않는다. 해외는 대표 결정(TAU1110A01: 해외는 구글)과 맞출지 정해야 한다.

### 결정 뒤에만 할 단위
- **U9. 공금**(`TripSharedFund`, 공금 %, 기여 비율로 공금 지출 귀속, 초과 사용 경고): `LedgerTrips.swift:79`의 대표 결정을 뒤집어야 한다.
- **U10. 지갑·가중평균 환율**: 환전·출금 기록이 필요하다. BOKKI `Kind`는 expense/income뿐이라, 열거값을 더하면 옛 빌드에서 행이 사라진다(U2로도 옛 빌드는 못 막는다). 이 엔진은 `TripDocument`에 강하게 묶여 있어 난이도가 상이다. 지금처럼 저장할 때 원화로 고정하는 방식이 단순하다.
- **U11. 영수증 카드 실제 청구액·쿠폰 배분**(`receiptCardAmounts`/`receiptCouponAmounts`, 순수 함수): 해외 카드 청구 문자를 붙일 때 같이 한다.
- **U12. 여행 예산 Live Activity**: 지표 18종 가운데 남은 예산·오늘·누적 몇 개만. 스틱맨(약 660줄)은 빼고, 갱신 빈도는 AGENTS.md를 따른다.
- **U13. 한국어 음성 지출 파서**(`Packages/TaptionVoice`, 의존성 없음): 금액·통화·엔빵·결제자를 읽는다. BOKKI의 `LedgerMessageParser`·Siri 지출과 역할이 겹치므로, 파서를 합칠지 정해야 한다.

## 4. 가져오지 않는 것과 이유

- **`.xlsx` 정본, `TripWorkbookCodec`, `TripStore`(2,695줄)**: BOKKI는 SQLite가 정본이다. 돈·Siri·Health가 한 클래스에 섞여 있다.
- **일정 UI**(`TripPlanningView`·`TimelineCanvasView`·`EditingSheets`, 약 1.1만 줄)
  - `TripStore`와 돈 필드에 얽혀 있다.
  - 240Hz 캔버스 계약이 BOKKI 규칙(그리기 120Hz, 레이아웃 60Hz)과 다르다.
  - 플랜 A/B/C(`AlternativeGroup`, 조건: 비·지연·휴무·피곤)는 아이디어로만 남긴다.
- **`HanaExchangeRateService`**
  - 공식 API 없이 Google Finance·네이버·하나·KB 화면을 정규식으로 긁는다.
  - 사이트가 바뀌면 깨지고 약관 위험도 있다.
  - "현찰 살 때" 환율이 필요하면 중계 서버에서 공개 API를 따로 검토한다.
- **계획·실제 정렬 엔진, HealthKit 숙소 자동 추가**: BOKKI의 센서 자동 기록·수면·provenance 규칙과 겹친다. 숙소 판정 수치(150m·20분·21~09시 2시간)만 비교 자료로 남긴다.
- **MapLibre / OpenFreeMap 지도 면**: BOKKI에 이미 MapLibre가 있다(백자 지도).
- **`TripEntitlement`(StoreKit Pro)**: IAP는 별도 재개 요청 전까지 보류다.
- **`TripImport`(자체 xlsx 사본 열기)**: BOKKI에는 JSON 여행 가져오기가 따로 있다.
- **WBS·주간 시간표·지도 메모 템플릿(`TaptionKit`)**: 여행과 무관하다.
- **`TripAssistSuggester`(FoundationModels로 제목 3개와 메모 1문장 제안)**: 작고 독립적이지만 BOKKI AI 다듬기와 겹친다. 필요하면 나중에 한다.

## 5. 이식할 때 공통 규칙

- Trip 코드는 복사가 아니라 옮겨 쓰기다. BOKKI의 이름 기반 동행(`@me` + 이름), 원화 고정, `LedgerEntry` 모양에 맞춘다. 순수 엔진은 BOKKI 타입에 묶지 말고 값 입력·값 출력으로 둔다.
- Trip 시험은 시나리오 숫자를 그대로 옮겨 같은 결과를 확인한다(예: 일본 4인 시나리오).
- 데이터 단위(U3~U5, U7)는 각각 다음을 입증한다.
  - 옛 JSON 읽기, 옛 빌드가 다시 저장해도 무사함
  - 백업 TAPTBK03 쓰기·읽기, TAPTBK02 읽기
  - 아이폰 11 실기기 저장·재열기
- AI 명령에 새 칸을 열면 앱과 서버를 함께 고친다. 서버 배포는 대표 허락 뒤에 한다.
- 작업 트리의 가계부 변경(`LedgerCapture`·`LedgerSheet`·`LedgerMemoLink` 등, LED1111A02·AIQ1111A01)이 커밋된 뒤 시작해 충돌을 피한다.
- 진행 중인 TAU1110A01(여행 자동화)의 "귀국 정산"과 LED1111A02의 단체 정산이 이 이식의 받는 자리다. 요청 ID를 따로 만들되 두 항목에 연결해 적는다.
