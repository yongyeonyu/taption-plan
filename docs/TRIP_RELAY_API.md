# AI 비서 → Taption Plan 여행 계획 연동 규격 (TRP1110A05)

도구 호출(HTTP 요청)이 되는 AI 비서(예: 피클, 맞춤 GPT Actions, 단축어)가 여행 계획을 앱으로 보내는 방법이다. 서버 코드는 `server/trip-relay`, 앱이 읽는 코드는 `TaptionPlan/UI/TripImportModel.swift`·`TripRelay.swift`다.

## 1. 주소와 인증

| 항목 | 값 |
|---|---|
| 주소 | `https://<RELAY_HOST>/plan` — 실제 호스트는 계정 이름이 들어 있어 저장소에 적지 않는다. 앱 빌드 설정 `TRIP_RELAY_HOST`와 같다 |
| 인증 | `Authorization: Bearer <연동 키>` 한 가지만 받는다(`X-Trip-Key` 같은 다른 헤더는 받지 않는다) |
| 연동 키 | 사용자마다 앱이 만든다: 여행 모드 → 추가 → AI로 만들기 → 「연동 키 만들기」. 무작위 32바이트를 base64url(패딩 없음)로 쓴 **43자** `[A-Za-z0-9_-]`. 「프롬프트만 복사」를 하면 프롬프트 끝에 주소와 키가 함께 들어간다 |
| 키 저장 | 앱은 기기 키체인에만, 서버는 SHA-256 해시만 둔다. 「새 키로 바꾸기」를 누르면 예전 키는 더 이상 받지 않는다 |

### 요청과 응답

| 요청 | 본문 | 응답 |
|---|---|---|
| `POST /plan` | 아래 여행 JSON(최대 64KB), `Content-Type: application/json` | `201` `{"ok":true,"tripId":"…","expiresInSeconds":259200}` |
| `GET /plan` | 없음 | `200` 저장된 JSON, `204` 없음 (앱이 쓴다) |
| `DELETE /plan` | 없음 | `204` (앱이 계획을 반영한 뒤 부른다) |

오류: `400` JSON 아님, `401` 키 없음·형식 틀림, `413` 64KB 초과, `422` 여행 형식 아님, `429` 보내기가 너무 잦음(IP당 1분 5번 안팎, Cloudflare 지역별 집계라 정확하지 않음), `404` 다른 경로, `405` 다른 메서드.

- 키마다 마지막 계획 하나만 둔다(새로 보내면 덮어씀). 서버는 3일 뒤 자동으로 지운다.
- 쓰고 나서 다른 지역에서 읽히기까지 몇 초 걸릴 수 있다. 앱은 열릴 때(포그라운드로 올 때) 가져와 처음 보는 내용이면 미리보기를 띄우고, 사용자가 반영하면 서버에서 지운다. 반영하지 않고 닫은 계획은 3일 동안 남아 「도착한 계획 불러오기」로 다시 열 수 있다.

```sh
curl -X POST "https://<RELAY_HOST>/plan" \
  -H "Authorization: Bearer <연동 키 43자>" \
  -H "Content-Type: application/json" \
  --data-binary @trip.json
```

## 2. 여행 JSON 스키마 (version 1)

키 이름은 영어, 글자 값은 사용자 언어로 쓴다.

### 최상위

| 필드 | 형식 | 필수 | 설명 |
|---|---|---|---|
| `format` | 문자열 | 필수 | 항상 `"bokki-trip"` |
| `version` | 정수 | 필수 | 항상 `1` (다른 값은 앱이 「앱보다 새 형식」으로 거절) |
| `tripId` | 문자열 | 필수 | 여행마다 한 번 정하고 계속 같은 값. 같은 `tripId`를 다시 보내면 앱이 바뀐 것(추가·변경·삭제)을 보여 주고 통째로 바꾼다 |
| `title` | 문자열 | 필수 | 여행 이름 |
| `items` | 배열 | 필수 | 일정 1~500개. 순서는 상관없다(앱이 시작 시각으로 정렬) |
| `startDate`, `endDate` | `YYYY-MM-DD` | 선택 | 기간 |
| `origin`, `destination` | `{name, lat, lng}` | 선택 | 지금 앱은 읽지 않는다(사람이 보는 정보) |
| `returnsToOrigin` | 불리언 | 선택 | 왕복 여부 |

### `items[]` 한 칸

| 필드 | 형식 | 필수 | 설명 |
|---|---|---|---|
| `id` | 문자열 | 필수 | 여행 안에서 겹치지 않는 값. 같은 여행을 다시 보낼 때 같은 일정이면 같은 `id`. 겹치면 앱이 뒤의 것에 `#2`처럼 차례 번호를 붙인다 |
| `type` | 문자열 | 필수 | `flight` `lodging` `meal` `cafe` `sight` `photo` `shopping` `activity` `rest` `sleep` `transfer` `other` 중 하나(모르는 값은 `other`) |
| `title` | 문자열 | 필수 | 일정 이름 |
| `start` | 시각 | 필수 | 현지 시차를 붙인다: `2026-12-01T09:05+09:00` (초·소수 초, `+0900`, `Z`도 받음). 읽지 못하면 그 계획 전체를 거절 |
| `end` | 시각 | 선택 | 없으면 시작 + 1시간. 항공편은 **도착지 시차**로 쓴다 |
| `place.name` | 문자열 | 권장 | 장소 이름 |
| `place.address` | 문자열 | 선택 | 주소(좌표가 없을 때 앱이 검색에 함께 쓴다) |
| `place.lat`, `place.lng` | 숫자 또는 `null` | 권장 | 구글 지도에서 찾은 좌표(소수 5자리). 모르면 `null` — 지어내지 않는다. 비면 앱이 이름·주소로 검색해 채운다 |
| `place.mapsUrl` | 문자열 | 권장 | 구글 지도 https 링크(google.*, goo.gl). 다른 주소는 앱이 버린다. 미리보기의 「구글 지도에서 보기」 |
| `flight.number` | 문자열 | 선택 | 편명(예: `TG659`) |
| `flight.fromAirport`, `flight.toAirport` | 문자열 | 선택 | IATA 코드 |
| `travelFromPrevious.mode` | 문자열 | 선택 | `walk` `transit` `car` `taxi` `flight` |
| `travelFromPrevious.minutes` | 숫자 | 선택 | 바로 앞 일정에서 오는 데 걸리는 분 |
| `note` | 문자열 | 선택 | 메모 |

종류별 뜻: `sight` 관광·가볼 만한 곳, `photo` 사진 명소, `activity` 호텔 수영장·스파·공연 같은 할 일, `rest` 쉬는 시간, `sleep` 취침~기상(장소는 숙소, 지도 핀은 찍지 않음), `flight`의 `place`는 도착 공항.

### 앱이 하는 일
- 붙여 넣은 글이면 앞뒤 설명과 ```` ```json ```` 울타리를 걷고 첫 `{`부터 마지막 `}`까지 읽는다(둥근 따옴표도 고친다).
- 날짜는 일정이 일어나는 곳의 현지 날짜로 묶는다. 여행 모드 시간 막대는 각 일정을 현지 벽시계 시각에 그린다.
- 반영하면 날짜별 장소(지도 핀·경로)와 시간 일정(시간표)을 만든다. 같은 `tripId`의 예전 내용은 지운다.

## 3. 샘플

```json
{
  "format": "bokki-trip",
  "version": 1,
  "tripId": "trip-20261201-bkk",
  "title": "방콕 3박 4일",
  "startDate": "2026-12-01",
  "endDate": "2026-12-04",
  "returnsToOrigin": true,
  "items": [
    {
      "id": "f1",
      "type": "flight",
      "title": "TG659 인천→방콕",
      "start": "2026-12-01T09:05+09:00",
      "end": "2026-12-01T13:05+07:00",
      "place": { "name": "수완나품 국제공항", "lat": 13.69, "lng": 100.7501, "mapsUrl": "https://maps.google.com/?q=Suvarnabhumi+Airport" },
      "flight": { "number": "TG659", "fromAirport": "ICN", "toAirport": "BKK" }
    },
    {
      "id": "h1",
      "type": "lodging",
      "title": "호텔 체크인",
      "start": "2026-12-01T15:00+07:00",
      "end": "2026-12-01T15:30+07:00",
      "place": { "name": "Siam Kempinski Hotel Bangkok", "address": "991/9 Rama I Rd, Bangkok", "lat": 13.7489, "lng": 100.5341, "mapsUrl": "https://maps.google.com/?q=Siam+Kempinski+Hotel+Bangkok" },
      "travelFromPrevious": { "mode": "taxi", "minutes": 45 }
    },
    {
      "id": "a1",
      "type": "activity",
      "title": "호텔 수영장",
      "start": "2026-12-01T16:00+07:00",
      "end": "2026-12-01T17:30+07:00",
      "place": { "name": "Siam Kempinski Hotel Bangkok", "lat": 13.7489, "lng": 100.5341 }
    },
    {
      "id": "m1",
      "type": "meal",
      "title": "쩟페어 야시장",
      "start": "2026-12-01T19:00+07:00",
      "end": "2026-12-01T21:00+07:00",
      "place": { "name": "Jodd Fairs", "lat": null, "lng": null },
      "travelFromPrevious": { "mode": "transit", "minutes": 25 }
    },
    {
      "id": "s1",
      "type": "sleep",
      "title": "취침",
      "start": "2026-12-01T23:00+07:00",
      "end": "2026-12-02T07:30+07:00",
      "place": { "name": "Siam Kempinski Hotel Bangkok", "lat": 13.7489, "lng": 100.5341 }
    },
    {
      "id": "t1",
      "type": "sight",
      "title": "왓 아룬",
      "start": "2026-12-02T09:00+07:00",
      "end": "2026-12-02T11:00+07:00",
      "place": { "name": "Wat Arun", "lat": 13.7437, "lng": 100.4888, "mapsUrl": "https://maps.google.com/?q=Wat+Arun" },
      "travelFromPrevious": { "mode": "taxi", "minutes": 30 },
      "note": "새벽 사원, 오전이 덜 붐빔"
    }
  ]
}
```

이 샘플은 `docs/trip-relay-sample.json`과 같고, 서버 검사(`isTripPlan`)와 앱 읽기(`TripImportParser`)를 모두 통과한다.
