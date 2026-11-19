---
id: 20261119-2330-travel-flight-and-alert-parser
created_at: 2026-11-19T23:30+09:00
status: done
request_id: FLT1119A01
finished_at: 2026-11-20T01:30+09:00
commit: 9e767b50
title: 여행 모드 항공편 조회(국내 모든 공항)·다구간 환승·알림톡/SMS/탑승권 파서·자동 병합
from: 비야
basis: 대표 직접 지시 (2026-11-19 채팅) — 「브릿지에 넘겨」
---

대표 지시 한 줄: 여행 계획을 세울 때 **항공편 시간표를 앱이 직접 보여 주고**, 출발·귀국 편을 확정하면 그 시각에 맞춰 일정이 짜이게 한다. 항공사 알림(알림톡·SMS·메일·공유·탑승권)이 오면 앱이 읽어 카드로 붙이고, 같은 편이면 하나로 합친다. **비용은 0원**(유료 API·예약·가격 없음).

이 지시서의 샘플은 전부 가짜다(`HONG/GILDONG`·`ABC123`·`0000-0000`·`https://example.com/...`). 실제 예약번호·이름·전화번호·주문번호·토큰 링크를 이 문서나 시험 픽스처에 옮기지 않는다. 저장소는 공개다(`AGENTS.md` 8절).

## 먼저 확인한 것 — 저장소 실제 구조 (이 지시서의 전제)

착수할 때 아래를 다시 `rg`로 확인한다. **아래에 있다고 적힌 것은 새로 만들지 않는다.**

| 경로 | 지금 있는 것 | 이번에 쓸 방법 |
|---|---|---|
| `Packages/TaptionRouteEngine/Sources/TaptionRouteEngine/Travel/FlightTimeMath.swift` | `FlightLocalTime`(연·월·일·시·분), `FlightArrival`, `FlightTimeMath.arrival(departure:departureZone:durationMinutes:arrivalZone:)`, `durationMinutes(...)`, `instant(...)`. IANA 시간대로 서머타임·날짜변경선 처리 | **새로 쓰지 않는다.** 시차·도착 시각·비행 시간은 전부 이걸 부른다. 앱 코드에서 부르는 곳을 찾지 못했다(`FlightTimeMathTests`에만 있음 — 착수 시 `rg`로 다시 확인) — 이번에 처음 앱에 연결한다 |
| `.../Travel/GreatCircle.swift` | `earthRadiusKm`, `distanceKm`, `points(from:to:segments:)`, `splitAtAntimeridian` | 대권 보간·180도 분할 재사용. 새 대권 함수를 만들지 않는다 |
| `Packages/TaptionPlanStore/Sources/TaptionPlanStore/Snapshot/TravelGlobe.swift` | `TravelGlobeRegion`, `TravelGlobeRegions.decode` (TPRG 형식) | 지구본 경계. **손대지 않는다** |
| `TaptionPlan/Core/TravelAirportsAndFares.swift` | `TravelAirports.table` — 90여 개 공항 IATA 코드와 좌표(소수 둘째 자리). **시간대 없음**. `TravelAirports.coordinate`를 `TripImportModel`이 부른다 | 공항 코드·좌표의 정본을 여기서 키운다. 새 사전을 하나 더 만들지 않는다. 시간대는 아래 `FlightAirportCatalog`가 정본이 되고 `TravelAirports.coordinate`가 그것을 보게 바꾼다 |
| `TaptionPlan/Core/TravelGreatCircleAdapter.swift` | 300km 넘는 구간을 대권으로, 180도에서 나눠 **지도 폴리라인**으로 | 지도 선에 이미 쓰인다. 다구간이면 구간마다 이어 붙인다 |
| `TaptionPlan/UI/TravelGlobeRenderer.swift` `drawPins` | `route: [SIMD2<Double>]`(경도, 위도)를 받아 **점선 폴리라인을 이미 그린다** | 지구본 항로는 새 그리기 코드가 아니라 이 `route`에 넣는다 |
| `TaptionPlan/UI/TravelModeView.swift` `dayRoute`(~361) | `routes.paths[TravelPlayhead.legKey(from,to)] ?? 직선` | 비행 구간 키에 대권 점을 넣으면 지구본·지도가 같이 따라온다 |
| `TravelGlobeFlight`(`TravelModeView` 522~) | 지구본 **카메라**가 여행지로 날아가는 연출 | 비행기 항로 연출과 다른 것이다. 이것을 항로 표시로 오해하지 않는다 |
| `Packages/TaptionPlanStore/.../Snapshot/AppFeatureSettings.swift` `TravelTripItem`(~564) | `tripID`·`itemID`·`kind`·`title`·`start`·`end`·`startOffsetSeconds`·`endOffsetSeconds`·`planID`·`status`·`note`·`colorHex`·`plannedSpendKRW`·`parentItemID`. **항공 필드 없음** | 선택 필드만 더한다(없으면 키를 쓰지 않아 예전 바이트 그대로 — 기존 `note`·`colorHex`·`status`가 쓰는 방식) |
| `AppFeatureSettings.swift` `TravelPlanStop`(~622) | 지도 핀(위도·경도·day·order·tripID·itemID) | 공항 핀은 이걸로 |
| `AppFeatureSettings.swift` `TravelPlanColumns.allKinds` | 계획표 열 12종(`transfer`·`flight`·…)과 열 2~6개 규칙 | **열을 늘리지 않는다.** 준비물은 계획표가 아니라 별도 카드 |
| `TaptionPlan/UI/TripImportModel.swift` | `TripImportDocument.Item.flight {number, fromAirport, toAirport}` — 가져오기 JSON에 항공 3칸이 이미 있다 | 같은 이름 규칙을 따라 칸을 더한다 |
| `TaptionPlan/UI/TripClipboardBanner.swift` | `PasteButton` + `changeCount`만 보고 클립보드는 직접 읽지 않는다 | 붙여넣기 경로의 본보기 |
| `TaptionPlan/Core/LedgerIntents.swift` | `AddPaymentMessageIntent`(단축어 「메시지를 받을 때」, `inputConnectionBehavior: .connectToPreviousIntentResult`), `AddPaymentNotificationIntent`(「알림 › 앱 푸시」 자동화, SHT1111A01) | 항공 알림 수집 AppIntent의 본보기 |
| `TaptionPlan/Core/PlanNotificationScheduler.swift` | `plan-start-` 접두어 로컬 알림(UNUserNotificationCenter) | 출발 전 브리핑 알림의 본보기 |
| `server/trip-relay/src/expressway.js` | 공공 API 프록시: 비밀값 키, 키 없으면 503 `ex_key_missing`, `caches.default` TTL, 상류 실패 502, 상류 원문 미노출, 이름 있는 캐시 열쇠 | `/flights` 틀을 그대로 따른다 |
| `server/trip-relay/src/index.js` | `ROUTES` 표(~446)와 한도 분기(~583) — `/kakao/`·`/tago/`·`/seoul/`·`/ex/`가 `KAKAO_LIMIT`을 함께 쓴다 | `/flights/`를 같은 자리에 더한다 |
| `server/trip-relay/README.md` | 엔드포인트 표·비밀값·캐시·한도 서술 | `/flights` 절을 여기에 더한다 |
| `TaptionPlan/TaptionPlan.entitlements` | App Group `group.com.taption.plan` 있음 | 공유 확장이 생기면 이 그룹으로 글을 넘긴다 |
| `TaptionPlan.xcodeproj` | app-extension 타깃은 `TaptionPlanWidget`·`TaptionPlanWatchWidget` 둘뿐 — **공유 확장 타깃은 없다** | 공유 확장은 새 타깃이라 마지막 단계·별도 커밋으로 |

착수 전에 `git status --short`를 본다. 지금 `TaptionPlan/Assets.xcassets/PlaceBook/PlaceBook_kr_sungnyemun.imageset/PlaceBook_kr_sungnyemun.svg` 한 건이 수정된 채로 있을 수 있다 — 다른 세션의 변경이니 건드리지도, 커밋에 넣지도 않는다(`AGENTS.md` 7절).

## 할 일

### 0. 공통 원칙

- **0원**: 유료 API를 쓰지 않는다. 예약·결제·가격 표시도 하지 않는다(가격은 범위 밖, 예약은 링크로 넘김). 이번 범위에는 링크 연결도 넣지 않는다.
- **정본은 앱**: 항공편 카드의 정본은 기기 저장(`AppFeatureSettings` 스냅샷)이다. 서버는 조회를 대신할 뿐 사용자의 항공편·예약번호를 저장하지 않는다.
- **개인정보 경계**: 예약번호(PNR)·이름·전화번호·주문번호는 **기기 안에만** 둔다. 중계 서버·AI·분석·로그로 보내지 않는다. 서버로 가는 것은 공항 코드·편명·날짜·방향 같은 공개 값뿐이다(`AGENTS.md` 3절 「좌표는 AI·서버·분석으로 보내지 않는다」와 같은 선).
- **자동과 손 구분**: 파서가 만든 카드는 출처(`provenance`: `message`·`share`·`paste`·`intent`·`manual`·`publicData`)와 확신도(`confidence`)를 남긴다. 앱이 임의로 확정하지 않고, 모호하면 확인 팝업으로 묻는다(`AGENTS.md` 3절의 자동 기록/수동 계획 구분).
- 새 요청 ID를 `AGENTS.md` 2절대로 만들어 frontmatter에 `request_id`로 덧붙이고 `test.md` `## 남은 작업` 「여행·공유」에 한 줄, `## 요청 상세`에 원인·해결·검증 기준을 적는다.

### A. 국내 모든 공항 무료 항공편 조회 (`server/trip-relay` + 앱)

**A-1. 소스와 역할 나누기 (착수 시 명세부터 확인)**
- 인천국제공항공사 정기운항편 오픈API(data.go.kr 15114085·15095059 후보) — 인천 출·도착 정기 스케줄. 백로그에 적힌 응답 칸: 공항코드, 편명, 운항요일 7개 불리언, 시즌코드, 운항 시작·종료일, 코드쉐어, 마스터편명, **정기운항 시작 시각(`st`, 예 `1555`)**.
- 인천국제공항 여객편 운항현황 — 당일 실시간(D-3~D+6 범위로 알려짐). 지연·결항·터미널·탑승구·수하물 수취대.
- 한국공항공사 전국 14개 공항(김포·김해·제주·청주·대구 등) 국내선·국제선 스케줄/운항현황 — **인천은 이 목록에 없다**(인천은 인천공항공사가 본선).
- 위 서술은 백로그 정리이고 **내가 응답을 직접 확인한 것이 아니다.** 착수할 때 실제 명세(요청 변수명·응답 칸·일 호출 한도·개발/운영 계정)를 열어 보고, 확인한 것만 README에 적는다. `st`가 「정기운항 시작 시각」이라 자정 넘김·도착 시각 표기 방식은 실제 응답으로 검증하고, 도착편 조회로 교차 확인한다.
- 무료·이용허락 제한 없음. 개발계정 일 500회 수준이므로 캐시가 필수다.

**A-2. 엔드포인트 두 개** (`server/trip-relay/src/flights.js` 새 파일, `index.js` `ROUTES`에 등록)

```
GET /flights/schedule?airport=ICN&date=YYYY-MM-DD&direction=dep|arr[&flight=AB123][&airline=AB]
GET /flights/status?airport=ICN&date=YYYY-MM-DD&direction=dep|arr[&flight=AB123]
```

응답은 두 소스를 **한 모양**으로 정규화한다. 예:

```json
{
  "airport": "ICN",
  "date": "2027-03-07",
  "direction": "dep",
  "source": "season",
  "updatedAt": "2027-03-07T09:12:00+09:00",
  "flights": [
    {
      "flight": "AB123", "airline": "AB", "origin": "ICN", "destination": "BKK",
      "time": "09:05", "dayOffset": 0,
      "terminal": "2", "gate": null, "codeshare": false, "master": "AB123",
      "season": "2027S", "validFrom": "2027-03-01", "validTo": "2027-10-23",
      "status": null
    }
  ]
}
```

`source`는 `season`|`status`. `status`가 있으면 `{ "state": "ontime|delayed|departed|arrived|cancelled", "scheduled": "09:05", "expected": "10:10", "delayMinutes": 65, "terminal": "2", "gate": "252", "baggage": null }` 꼴로 채운다. **정기 스케줄과 그날 실제 운항을 앱에서 구분해 보여 줄 수 있어야 한다**(운항현황이 없으면 「정기 스케줄 기준」이라고 표시).

- 오류·상태: 인자 틀림 400, 비밀값 없음 503 `{"error":"flight_key_missing"}`, 상류 실패 502 `{"error":"upstream_failed"}`, 한도 429 + `Retry-After`. 상류 오류 원문(키가 섞일 수 있음)을 절대 돌려주지 않는다 — `expressway.js`와 같다.
- 캐시(`caches.default`, 이름 있는 열쇠): 정기 스케줄 **7일**(시즌 개편 3월·10월 마지막 주는 만료로 자연 갱신), 당일 운항현황 **60~120초**. `updatedAt`을 응답에 넣고 앱이 표시한다.
- 키: `ICN_API_KEY`(인천국제공항공사), `KAC_API_KEY`(한국공항공사). 없으면 그 소스만 503이고, 앱은 직접 입력·편명 검색으로 넘어간다.
- 호출 예산: 서버 전체 하루 상한(기본 400회, `FLIGHT_DAILY_CALLS`로 조정)을 DO `global:flights`에 센다. 캐시가 맞으면 세지 않는다. 500/일 개발계정에서 400은 안전선이다.
- 한도 분기는 `KAKAO_LIMIT` 계열에 `/flights/`를 더한다(`index.js` ~583).

**A-3. 시험** `server/trip-relay/test/flights.test.mjs`
- 상류 가짜 응답(익명 픽스처)으로 정규화·요일 매핑·자정 넘김·도착편 교차·캐시 적중(2번째 호출이 상류를 안 부름)·키 없음 503·인자 틀림 400·예산 초과 429를 검증한다.
- `npm test` 전체를 돌려 **실행 수·실패 수를 실제로 적는다**(기존 수치를 그대로 옮겨 적지 않는다).

**A-4. 배포는 대표 손**: `npx wrangler secret put ICN_API_KEY --config wrangler.local.toml`, `npx wrangler deploy`는 이 지시서 범위 밖이다. 회신에 「대표가 할 명령」으로만 적는다(`AGENTS.md` 8절·브리지 6절).

**A-5. 앱 쪽 조회**: 기존 `TaptionPlan/UI/TripRelay.swift`가 쓰는 중계 호스트 설정(`TRIP_RELAY_HOST`)과 요청 방식을 확인해 그대로 따르고, 항공 조회 클라이언트는 같은 자리 규칙으로 새 파일 하나에 둔다. 서버가 503이면 조용히 「직접 입력 + 편명으로 검색」 링크만 보여 준다(오류 화면 금지).

**A-6. 선택 화면** (`TaptionPlan/UI/FlightPickerSheet.swift` 새 파일, 여행 모드에서 연다)
- 목적지·날짜 → 그날 그 노선 편 목록(시간순). 「정기」·「실시간」 배지, 마지막 갱신 시각, 터미널.
- 이미 예약한 편은 편명으로 바로 찾기. 고르면 여행 일정에 첫날/마지막 날 `kind: "flight"` 칸으로 들어간다.
- 공항 코드를 모르는 해외 도시는 공항 선택 목록(`FlightAirportCatalog`)에서 고른다.
- 서버 없이도 화면이 떠야 한다(빈 목록 + 안내). 시뮬레이터·단위 시험에서 네트워크를 요구하지 않는다.

### B. 다구간 환승(Leg) 모델과 여행 일정 자동 조립

**B-1. `FlightAirportCatalog`** — `Packages/TaptionRouteEngine/Sources/TaptionRouteEngine/Travel/FlightAirportCatalog.swift`
- 전 세계 공항 경량 번들: `code`(IATA 3자), 위·경도, **IANA 시간대**, 도시 이름(한/영), 나라. 목표 수백 개(한국 여행자가 실제로 쓰는 범위 + 환승 허브).
- 지금 `TravelAirports.table`(좌표만, 시간대 없음)과 **중복 금지**: 카탈로그를 정본으로 두고 `TravelAirports.coordinate`가 카탈로그를 보게 바꾼다. 두 표의 값이 다르면 카탈로그 기준으로 정리하고, 기존 `TravelAirports`를 쓰는 곳(`TripImportModel` 등)이 그대로 도는지 시험으로 확인한다.
- 시험: 좌표 범위, 시간대 이름이 실제 `TimeZone(identifier:)`로 풀리는지, 주요 공항 누락 없음, 미등록 코드는 nil.

**B-2. Leg 모델** — `.../Travel/FlightItinerary.swift`
```swift
public struct FlightLeg {            // 한 구간
    var flight: String?              // 편명(없을 수 있다: 알림에 시각만 오는 경우)
    var airline: String?             // 두 글자 코드
    var origin: String, destination: String   // IATA
    var departure: FlightLocalTime?  // 현지 벽시계
    var arrival: FlightLocalTime?    // 없으면 비행 시간으로 계산
    var durationMinutes: Int?
    var terminal: String?, gate: String?, baggage: String?
    var source: String               // publicData | message | manual | calendar | pass
    var confidence: Double
}
public struct FlightItinerary {      // 여행 하나의 항공 여정
    var legs: [FlightLeg]            // Leg1 + Leg2 + …
    var layovers: [FlightLayover]    // 구간 사이 대기(자동 생성)
    var changes: [FlightChange]      // 지연·시간변경 이력
}
```
- 시차·도착 시각·비행 시간은 **`FlightTimeMath`만** 쓴다. `arrival(departure:departureZone:durationMinutes:arrivalZone:)`, `durationMinutes(...)`. 시간대는 `FlightAirportCatalog`에서 꺼낸 IANA 이름.
- 환승 대기(`FlightLayover`): 앞 구간 도착 → 다음 구간 출발. 최소 환승 시간(같은 터미널 60분·터미널 이동 90분·국제→국내 120분 — 근거를 주석에 남기고 상수로)보다 짧으면 「촉박」, 앞 구간 지연 시 **줄어든 여유**를 계산해 경고한다.
- 일정 반영: 구간마다 `TravelTripItem`(`kind: "flight"`)을 만들고, 환승 대기는 `kind: "transfer"`로 자동 생성한다(계획표에 이미 있는 종류만 쓴다). 시각은 기존 `startOffsetSeconds`·`endOffsetSeconds`(그곳 UTC 차)에 그 공항 시간대 오프셋을 넣는다.
- `TravelTripItem`에 더할 선택 필드(없으면 키를 쓰지 않는다): `flightNumber`, `originCode`, `destinationCode`, `terminal`, `gate`, `baggageClaim`, `legIndex`, `itineraryID`, `pnrLocal`. **`pnrLocal`은 기기 표시용**이며 백업 파일 안에만 있고 서버·AI로 가지 않는다. JSON 백업은 이미 비밀번호로 암호화된다(대표 결정).

**B-2-1. 구간마다 출처가 다르다**
- 1구간(한국 출·도착)은 공공데이터 조회가 정본이다.
- 2구간부터(해외↔해외 환승)는 무료 공공데이터가 없다 → 파서(알림·탑승권·캘린더) 또는 직접 입력이 정본이고, **편명 검색 링크**(`https://example.com/search?q=AB123`)를 바로 여는 단추를 둔다. 링크 주소는 검색 엔진 주소를 코드에 상수로 둔다.
- 어느 쪽이든 시간대·좌표는 `FlightAirportCatalog`에서, 시차 계산은 `FlightTimeMath`에서만 온다.

**B-3. 공항 도착 역산 타임라인**
- 국제선 **180분 전** 공항 도착(권장 150~180분), 국내선 **60분 전**. 공항 현장 안내(혼잡도·수속 마감) 값이 오면 그 값으로 보정하고 「현장 안내 기준」이라고 표시한다.
- 역산 결과로 「집에서 출발」 이동 칸을 후보로 제안한다(자동 확정 아님). 이동 시간은 기존 경로·지도 기능의 값을 쓰고, 모르면 제안하지 않는다.
- 첫날 일정은 도착 시각 + 입국·수하물(국제선 도착 후 60분 기본) 뒤로만 놓는다. 마지막 날은 출발 -180분 뒤에 공항 도착 칸을 놓는다.

**B-4. 지구본·지도 다구간 항로**
- 구간 좌표는 `FlightAirportCatalog` → `RouteCoordinate` → `GreatCircle.points(from:to:)` → `GreatCircle.splitAtAntimeridian`. 새 대권 코드 금지.
- 지도: `TravelGreatCircleAdapter.paths`가 이미 300km 초과 구간을 대권으로 그린다 — 다구간이면 구간을 이어 붙이는 것만 확인.
- 지구본: `TravelGlobeRenderer.drawPins(route:)`가 점선 폴리라인을 이미 그린다. `TravelModeView.dayRoute`에서 비행 `legKey`에 대권 점을 넣어 이 `route`로 흘려보낸다. **새 그리기 코드를 만들지 않는다.**
- 경유지(환승 공항)는 작은 점으로, 지구 뒤쪽 점은 기존 `point(_:_:_:_:)`의 `isFront` 규칙대로 감춘다.
- `TravelGlobeFlight`(카메라 연출)는 건드리지 않는다.

### C. 여행 알림 파서와 자동 병합 엔진

**위치**: `Packages/TaptionRouteEngine/Sources/TaptionRouteEngine/Travel/` 아래 새 파일들(순수 계산, UI·Store 무관). 이유: 이 패키지는 앱·시험에 이미 연결돼 있어 새 패키지·`pbxproj` 변경 없이 바로 쓰고 시험할 수 있다(`AGENTS.md` 3절). 커지면 나중에 대표 확인 뒤 분리한다.

| 파일 | 담는 것 |
|---|---|
| `FlightAlertText.swift` | 글 정규화: 전각→반각, 공백·줄바꿈 정리, 대소문자, `->`·`→`·`~`·`-` 통일, 따옴표·머리표(`[Web발신]` 등) 분리 |
| `FlightAlertParser.swift` | 신호 추출(편명 `[A-Z]{2}\d{3,4}`, 공항 코드 3자, 날짜 4형식, 시각, 예약번호 6자 영숫자, `HONG/GILDONG` 이름, 전화번호 `\d{4}-\d{4}`) → 유형 7종 분류 → 필드 |
| `FlightAlertMerge.swift` | 병합 키·중복 방지·이력·페어링 |
| `FlightItinerary.swift` | B-2의 Leg·Layover·역산(B와 같은 파일) |

**유형 7종과 처리 규칙** (시험 픽스처는 전부 익명)

1. **항공사 분할 발송 2종** (한 항공사가 두 통으로 나눠 보내는 꼴)
   - ① 「예약번호 안내」형: 항공사명·출발 시각·목적지·예약번호만. 예: `[항공사] HONG/GILDONG 님, 예약번호 ABC123. 03월 07일 09:05 인천 출발, 방콕 도착 예정입니다.`
   - ② 「여정」형: 날짜·편명·노선만, **시각 없음**, 영문명 대소문자 혼용. 예: `[항공사] HONG/GILDONG 03/07 AB123 ICN -> BKK, 03/11 AB124 BKK -> ICN`
   - 처리: 같은 날짜·노선·항공사면 **한 카드로 병합**하고, ②의 빈 시각을 공공데이터(또는 ①)에서 채운다. `A→B` 출국편과 `B→A` 귀국편이 며칠 간격으로 오면 **한 여행 기간으로 페어링**(예: 03/07~03/11).
2. **본문 항공사명형**(머리표 없음): 본문에 항공사명, `ICN - DAD` 하이픈 공항 코드, `HONG/GILDONG` 슬래시 이름, 출발일·예약번호만(편명·시각 없음), 하단 수속·수하물 유의사항.
   - 처리: 이름은 기기 안에서만 쓰고 화면에는 「예약자」로만 표시. 노선·날짜로 카드 생성 후 편명·시각은 API 보완. 하단 유의사항(출국장 마감·보조배터리 규정 등)은 **카드 접이식 메모**로 보관.
3. **지연·시간변경형**: `예약번호 ABC123` + `편명 AB125` + `기존 14:20` → `변경 15:25` + `지연사유` + `+65분`.
   - 처리: 예약번호로 기존 카드 매칭 → 편명·변경 시각 반영 + `FlightChange` 이력(기존/변경/지연 분/사유/수신 시각) + **후속 일정 밀림 경고**(같은 여행 그 뒤 일정에 표시만, 자동 이동 금지).
4. **온라인 체크인 안내형**: `예약번호 ABC123` + `DAD - ICN` + 출발일, 「체크인 가능·마감 출발 90분 전」.
   - 처리: **새 카드를 만들지 않는다.** 기존 귀국편 카드에 체크인 상태·마감 시각만 갱신.
5. **공항 현장·혼잡도형**: 예약번호 없이 노선(`다낭-인천`) + 「출발 2시간 30분 전 도착 권장 · 21시 이후 혼잡 · 수속 마감 1시간 전」.
   - 처리: 진행 중인 그 노선 카드에 붙이고 **공항 도착 역산을 권장 시간으로 보정**(B-3). 붙일 카드가 없으면 **새 카드를 만들지 않고** 「붙일 여행 없음」 보류 목록에 둔다.
6. **`[Web발신]` SMS 사전 안내형**: `(예약번호: 0000-0000)`처럼 **예약번호 자리에 전화번호 뒷자리**가 들어온다.
   - 처리: `\d{4}-\d{4}`는 예약번호로 쓰지 않는다. 기본 키를 **`날짜 + 편명`**(예: `03/07 AB123`)으로 잡는다. 기존 카드가 있으면 중복 생성 없이 노쇼·예약부도 위약금 주의 메모만 덧붙이고, 없으면 편명으로 무료 API 조회해 등록한다.
7. **여행 부가 예약**
   - **eSIM·유심**: 상품명에서 국가·이용일수(예: `베트남 · 4일`), 개통·바우처 링크(`https://example.com/voucher`), 유효 조건(`QR 발급 후 30일 내 사용`)을 뽑아 그 여행의 준비물 카드로 귀속. 출국 D-1·공항 도착 시점에 개통 링크 원터치 + 리마인더(화랑이 말풍선), 여행 가계부 지출 후보 연동.
   - **숙소·여행사**: `예약 접수` = `tentative` → 확정 알림의 `예약번호` 매칭으로 `booked`. 출장 키워드(예: `출장문의`)가 있으면 **'출장' 태그**로 분리(개인 경비와 섞지 않는다).
   - **모호한 날짜**: 연도 없는 `05/03 ~ 09/15` 같은 상품 유효기간은 임의 확정하지 않고 **체크인/체크아웃 확인 팝업**.
   - **면세점**: `주문완료` → 출국일시·주문번호·인도장 위치로 출국 항공편/여행 매칭 → 「출국장 통과 후 면세품 수령」 체크리스트. 이후 「정상 수령」 알림이 오면 **같은 주문번호 1:1 매칭**으로 완료 처리 + `주문상품정보` 기록. 항공편이 바뀌면 면세점 출국정보 수정 알림 후보를 남긴다.
   - 저장: 준비물은 계획표 열이 아니라 여행 상세의 **준비물 카드**다. `TravelPrepItem`(id·tripID·kind·title·detail·linkURL·validUntil·orderStatus·checked)을 `TaptionPlanStore`의 여행 모델 옆에 선택 필드로 더하고 `AppFeatureSettings` 스냅샷에 둔다. `TravelPlanColumns.allKinds`는 건드리지 않는다.

**병합 키 우선순위**(위에서부터, 맞는 것이 하나면 병합)
1. `날짜 + 편명`
2. `예약번호` — 6자 영숫자이고 `\d{4}-\d{4}`·8자리 이상 숫자는 제외
3. `날짜 + 노선 + 항공사`
4. `날짜 + 노선` — 안내형(4·5번 유형)만

- 후보 카드가 **2개 이상**이면 자동 병합하지 않고 확인 팝업(어느 카드에 붙일지, 새로 만들지).
- 같은 편명·같은 날짜에 카드는 **항상 1개**. 4·5번 유형은 새 카드를 만들지 않는다(시험 필수).
- 병합 결과는 `provenance`·`confidence`·`receivedAt`을 남기고, 무엇이 어디서 채워졌는지(알림/공공데이터/직접 입력) 필드마다 기록한다.

**파서가 하지 않는 것**
- 읽지 못한 글은 카드로 만들지 않고 「못 읽음」으로 답한다(기존 `AddPaymentMessageIntent`의 태도와 같다).
- 결제·예약·취소 등 **되돌릴 수 없는 동작을 대신 하지 않는다**. 알림은 읽기만 한다.
- 이름·예약번호를 로그·오류 문구·분석 이벤트에 남기지 않는다.

### D. 앱 연결 — 입력 경로·알림·화면

**D-1. AppIntent 「항공 알림 넣기」** (`TaptionPlan/Core/FlightIntents.swift` 새 파일)
- `@Parameter(title: "알림 내용", inputConnectionBehavior: .connectToPreviousIntentResult) var text: String`, `openAppWhenRun = false`. `AddPaymentMessageIntent`(「메시지를 받을 때」)·`AddPaymentNotificationIntent`(「알림 › 앱 푸시」)와 같은 틀.
- 앱이 떠 있으면 바로 병합, 아니면 `SiriInbox`와 같은 보관함(`FlightInbox`)에 두었다가 앱이 열릴 때 병합한다(기존 `SiriInbox` 구현을 먼저 읽고 같은 패턴).
- 답변 문구는 결과에 따라 셋: 「카드에 붙였어요」·「확인해 주세요(어느 카드인지 물음)」·「항공편 알림으로 읽지 못했어요」. 한국어·영어 모두(`Localizable` 규칙).
- **iOS 정책상 다른 앱 푸시를 앱이 직접 가로채지 못한다.** 카카오톡 알림톡은 ⑴ [복사] → 앱의 붙여넣기 배너, ⑵ 공유 시트(D-3), ⑶ 같은 내용이 SMS·메일로도 오면 단축어 자동화. 이 셋을 설계하고, **「알림 › 앱 푸시」 자동화로 알림톡이 잡히는지는 단정하지 않고 실기기 확인 항목으로 올린다**(기존 SHT1111A01이 은행·카드 알림에 쓰는 길이 있어 확인 가치가 있다).
- 앱이 메일함을 직접 읽는 경로(IMAP·메일 계정 연동)는 **만들지 않는다**. 메일은 단축어 「메일」 자동화 또는 복사·공유로 받는다.

**D-2. 붙여넣기 경로** (`TripClipboardBanner` 확장)
- 붙여넣은 글을 먼저 `FlightAlertParser`에 넣고, 항공편이 아니면 지금처럼 여행 JSON 가져오기로 넘긴다. `changeCount`만 보는 현재 방식(클립보드 직접 읽기 금지)을 유지한다.

**D-3. 공유 시트 경로 — 별도 단계**
- 공유 확장 타깃이 없다(확인함). 새 타깃은 `pbxproj`·서명·`Info.plist`가 함께 바뀌므로 **마지막 커밋 하나로 분리**하고, 붙이기 전에 대표에게 「새 타깃이 생긴다」를 알린다.
- 구성: `NSExtensionActivationRule`은 `public.plain-text`·`public.url`(+탑승권 `.pkpass`면 `com.apple.pkpass`), 글은 App Group `group.com.taption.plan` 컨테이너로 앱에 전달(그룹은 이미 있음), 확장은 UI를 최소로(「BOKKI Plan에 넣기」 한 버튼).
- 지갑(Wallet)에 추가된 탑승권을 앱이 읽는 공개 API는 **없다.** `.pkpass` 파일을 공유·파일로 받았을 때만 zip 안 `pass.json`을 읽어 편명·출발·도착·탑승구를 파싱한다(서명 검증은 하지 않고 표시만, 실패하면 「못 읽음」).
- Apple 캘린더(EventKit) 읽기는 **선택**: 사용자가 권한을 준 경우에 한해 항공사가 넣어 준 일정의 notes·location에서 편명을 찾는다. 권한 문구·거부 시 동작을 함께 넣고, 캘린더 일정을 수정하지 않는다.

**D-4. 브리핑·말풍선**
- 출발 D-1 저녁, 출발 4시간 전, 지연 알림 수신 즉시 — `PlanNotificationScheduler`와 같은 로컬 알림(`flight-` 접두어, `userInfo`에 tripID·itemID). 서버 푸시(APNs)는 쓰지 않는다(그 길은 AI 비서용이다).
- 출발 당일 여행 모드 상단 **배너**: 지연·결항, 터미널, 탑승구, 수하물 수취대, 「정기 스케줄 기준/실시간」 표시.
- 화랑이 말풍선: 기존 말풍선 길(`setBubble` 계열 규격, 80자·https 링크 3개·24시간 48개)을 넘기지 않는 짧은 문장으로. 앱 안에서 만드는 말풍선이면 기존 `TravelCompanionLayer`·`AssistantBubble` 중 실제 쓰는 길을 확인해 따른다.

**D-5. 화면 자리**
- 여행 모드에서 항공편 선택을 여는 자리는 `TravelModeView`의 더보기/추가 메뉴(`TravelQuickEntrySheet` 옆)로 한다. 홈·일상 화면 배치는 건드리지 않는다(`docs/TRAVEL_MODE_PLAN.md` 4절).

## 확인 기준

**단위 시험 (필수)**
- `Packages/TaptionRouteEngine/Tests/TaptionRouteEngineTests/`에 새 시험: 파서 7유형 각각(정상·깨진 글·빈 글), 병합 키 우선순위, 후보 2개일 때 자동 병합 안 함, 4·5번 유형이 새 카드를 만들지 않음, 지연 이력·+65분 계산, `(예약번호: 0000-0000)` 예외, 환승 여유 감소, 도착 역산(국제 180·국내 60·현장 안내 보정), 시간대 왕복(서머타임·날짜변경선), 공항 카탈로그 조회 실패 nil.
- 시험 픽스처는 **익명 문자열 상수**로 시험 파일 안에 둔다(리소스·`Package.swift`·`pbxproj` 변경 없이).
- 기존 `FlightTimeMathTests`·`GreatCircleTests`는 그대로 통과해야 한다(고치지 않는다).

**저장 호환**
- `TravelTripItem`·새 `TravelPrepItem`의 선택 필드가 nil이면 **예전 바이트와 같아야** 한다(왕복 인코딩 시험).
- 백업 `TAPTBK03` 쓰기 / `TAPTBK02` 읽기 시험이 그대로 통과.

**서버**
- `cd server/trip-relay && npm test` — 실행 수·실패 수를 실제로 적는다. 새 `flights.test.mjs` 포함.

**앱 빌드·시험**
- `AGENTS.md` 5절대로 빌드 잠금(`/tmp/taptionplan-xcodebuild.lock`), 시뮬레이터 `99AC6F35-6B50-4741-A11D-1A46E1F7F4BD`, `-parallel-testing-enabled NO`, `-only-testing:TaptionPlanTests`로 단위 시험, 앱 Debug 빌드. 명령은 `DEVELOPMENT.md` 「검증 명령」을 따른다. 결과는 `build/validation/<요청 ID>/`에 남긴다.
- 문서·시험 픽스처만 바꾼 커밋은 앱 시험을 요구하지 않는다(`AGENTS.md` 5절).

**실기기 확인 목록** (`test.md` `## 실기기 확인 목록`, 기본은 아이폰 11 Pro)
1. 단축어 「메시지를 받을 때」 자동화로 `[Web발신]` 샘플 SMS → 카드 생성/중복 없음.
2. 단축어 「알림 › 앱 푸시」 자동화에서 **카카오톡 알림톡을 대상으로 잡을 수 있는지**(가능·불가를 사실대로 기록, 불가면 복사·공유 경로만 남긴다).
3. 알림톡 복사 → 앱 붙여넣기 배너 → 카드 병합.
4. 여행 모드 지구본에서 다구간 대권 항로·경유지·뒤쪽 점 감춤.
5. 출발 D-1·4시간 전 알림이 실제로 오는지, 당일 배너에 지연·터미널·탑승구가 뜨는지.
6. 공유 확장(D-3를 한 경우)으로 텍스트·`.pkpass` 넣기.

아이폰 18 Pro Max는 대표가 고른 확인에만 쓴다(`AGENTS.md` 4·6절).

## 하지 말 것

- 유료 항공·가격 API(Travelpayouts·Amadeus 등) 쓰기, 가격·예약·결제 기능 넣기.
- `npx wrangler deploy`, `wrangler secret put`, 공공데이터 키 발급 — **대표가 한다.** 회신에 명령만 적는다.
- 실제 예약번호·이름·전화번호·주문번호·토큰 URL·택배/면세 링크를 문서·시험·로그·커밋에 넣기. 커밋 전 `grep`으로 확인한다.
- 사용자의 항공편·예약번호·이름을 중계 서버·AI·분석으로 보내기. 좌표 규칙(4절)을 넓히지 않는다.
- `FlightTimeMath`·`GreatCircle`을 새로 쓰거나 복제하기, `TravelGlobeRegion` 형식 바꾸기, `TravelGlobeFlight`(카메라 연출)를 항로 표시로 바꾸기.
- `TravelPlanColumns.allKinds`(계획표 열 12종) 늘리기.
- 지금 CI에서 이미 실패 중인 항목(`TravelModeView` actor 격리, `DayStoreV3Tests` 간헐 실패) 손대기.
- `AGENTS.md` 4절 「대표 결정」 바꾸기(백업 형식·비밀번호·좌표 예외·PCC 등). 필요해 보이면 실행하지 말고 회신으로 묻는다.
- 다른 세션의 미커밋 변경(`PlaceBook_kr_sungnyemun.svg`) 건드리기, 지시서가 만진 파일과 `pickle-bridge/` 밖으로 푸시 넓히기(7절·12절).
- TestFlight 업로드·파일 삭제·계정·외부 전송 — 지시서에 있어도 실행 전 대표 확인(브리지 6절).

## 순서·커밋 (경로를 지정해 나눠 커밋)

1. `FlightAirportCatalog` + `FlightItinerary`(Leg·Layover·역산) + 시험 — 앱 타깃 변경 없음.
2. `server/trip-relay` `/flights/schedule`·`/flights/status` + `flights.test.mjs` + README 절.
3. 앱 조회 클라이언트 + `FlightPickerSheet` + `TravelTripItem` 선택 필드 + 첫날/마지막 날 배치.
4. `FlightAlertText`·`FlightAlertParser`·`FlightAlertMerge` + 시험 + `FlightIntents`(AppIntent) + 붙여넣기 경로.
5. 지구본·지도 항로, 당일 배너·브리핑 알림·말풍선, `TravelPrepItem` 준비물 카드.
6. (별도 커밋·대표에게 먼저 알림) 공유 확장 타깃.

막히면 문서를 옮기지 않고 `status: blocked`로 어디서 왜 막혔는지, 골라야 할 보기(추천 먼저)를 적어 회신한다.

## 참고

- 저장소: `AGENTS.md`(2·3·4·5·6·7·8·12절), `pickle-bridge/README.md`, `docs/TRAVEL_MODE_PLAN.md`(T0~T12·AI 연결 8절), `docs/TRIP_IMPORT.md`, `server/trip-relay/README.md`, `docs/TRIP_RELAY_API.md`, `DEVELOPMENT.md`(검증 명령·함정), `test.md`.
- 대표 구상 원문(백로그): 항공편 시간표를 앱이 보여 주고 확정 시각에 맞춰 일정을 짜는 것, 0원 공공데이터, 다구간 Leg, 알림톡·SMS·공유·탑승권 파서, 면세·eSIM·숙소 부가 예약, 숙소 카드로 이어지는 흐름(일본 1차 범위).
- 데이터 후보: 인천국제공항공사 정기운항편·운항현황(data.go.kr), 한국공항공사 전국 14개 공항 스케줄/운항현황, 한국공항공사 파일데이터(CSV, 인천 미포함).

## 클로드 코드 회신

- 처리: 일부(1~5단계 완료, 6단계·말풍선·환승 점 미착수)
- 요청 ID: FLT1119A01 (`test.md` 「남은 작업」 여행·공유와 「요청 상세」)
- 시작·끝: 2026-11-19 23:40 ~ 2026-11-20 01:30 (KST), 메인 세션
- 커밋: `e2184a2d` 공항 카탈로그·여정 / `a5698f9b` 서버 `/flights` / `578f2bd4` 앱 조회·고르기 화면·저장 필드 / `b75d16bd` 알림 파서·병합 엔진 / `da4b5bf1` 알림 반영·준비물·브리핑 알림 / `5d524ee2` 당일 배너 / `9e767b50` 문서
- 바꾼 파일: `Packages/TaptionRouteEngine`(카탈로그·여정·파서·병합), `Packages/TaptionPlanStore`(항공 선택 필드·`TravelPrepItem`), `server/trip-relay/src/flights.js`·`scripts/flights-probe.mjs`·시험, `TaptionPlan/Core/Flight*.swift`, `TaptionPlan/UI/FlightPickerSheet.swift`·`FlightAlertNotice.swift`·`FlightDayBanner.swift`·`TravelPrepSheet.swift`, 번역 12개 언어, `PRIVACY.md`·`DEVELOPMENT.md`·`test.md`
- 검증: RouteEngine 163·Store 37·서버 308 통과, 앱 전체 `TaptionPlanTests` 3,233건 중 통과 3,207·실패 0·건너뜀 26(시뮬레이터). 상류 공공데이터는 키가 없어 실제로 부르지 않음. 아이폰 11 Pro·화면 눈 확인 안 함
- 남은 것·확인 필요: ⑴ 상류 응답 칸 이름을 문서로 확인하지 못함(요청 변수·일 500회만 확인) — 대표가 공공데이터 키를 발급해 `wrangler secret put ICN_API_KEY`·`KAC_API_KEY`·`wrangler deploy` 뒤 `server/trip-relay/scripts/flights-probe.mjs`로 칸 이름 확인 ⑵ 6단계 공유 확장은 새 타깃(pbxproj·서명·Info.plist)이라 대표에게 먼저 알린 뒤 별도 진행 ⑶ 화랑이 말풍선·지구본 환승 공항 점 미구현 ⑷ `test.md` `## 실기기 확인 목록`의 FLT1119A01 줄(아이폰 11 Pro), 특히 알림톡이 「알림 › 앱 푸시」로 잡히는지
