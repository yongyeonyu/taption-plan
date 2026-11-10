# AI 대화로 여행 계획 가져오기 (TRP1110A01)

사용자는 앱에서 레퍼런스 프롬프트를 복사해 ChatGPT·Claude·Gemini 같은 AI에 붙여 넣습니다. AI는 객관식 질문으로 여행 계획을 함께 세우고, 마지막에 아래 형식의 JSON을 출력합니다. 사용자가 그 JSON을 앱에 붙여 넣으면, 앱이 미리보기를 보여 준 뒤 여행 모드의 지도 경로·시간 막대·일정에 그대로 반영합니다.

## 정한 설계

| 항목 | 결정 |
|---|---|
| 반영 내용 | 날짜별 장소 목록과 항공편·숙소·식당·관광·쇼핑의 시간 일정(타임라인 포함) |
| 좌표 | AI가 구글 지도에서 찾아 위경도와 구글 지도 링크를 넣음. 앱은 국내 카카오·해외 Apple 검색 좌표와 비교해 멀면 경고 |
| 반영 방식 | 미리보기 후 반영. 항목별로 빼거나 고칠 수 있음 |
| 시작 위치 | 여행 모드 하단 `추가` → AI로 만들기(프롬프트 복사·JSON 붙여넣기). 앱을 열 때 클립보드에 여행 JSON이 있으면 가져올지 물음 |
| 질문 순서 | 출발지·목적지·기간·왕복 → 여행 스타일·속도 → 기상·취침 시간 → 항공편 → 숙소 추천 → 날짜별 일정 초안 → 하루씩 다듬기 → 이동 시간 확인 → 최종 확인 → JSON → 수정하면 전체 JSON 다시 |
| 역할 | AI가 먼저 검색해 호텔·관광지·사진 명소·식당·카페·쇼핑·호텔 활동(수영·휴식)을 추천하고 매일 기상~취침 안에 짜며 이동 시간까지 계산, 사용자는 주고받으며 다듬음. 앱은 최종 JSON을 확인·시각화 |
| 다시 붙여넣기 | `tripId`가 같으면 같은 여행. 추가·변경·삭제를 표시한 뒤 새 내용으로 교체(앱에서 손으로 고친 것은 덮어씀) |
| 보여 주기 | 날짜를 고르면 지도에 그날 핀과 순서 경로, 시간 막대에 일정, 재생하면 화랑이가 일정대로 이동 |
| 이동 시간 확인 | 앱이 Apple 길찾기로 다시 재서 AI 시간과 크게 다르거나 다음 일정에 늦으면 경고 |
| 언어 | 프롬프트 본문과 JSON 키는 영어 고정. AI가 사용자에게 묻는 말만 앱 언어 |
| 나중에 | 예산, 동행자 |

## 레퍼런스 프롬프트 (초안)

앱은 `{LANGUAGE}`를 앱 언어 이름(예: Korean)으로, `{TODAY}`를 오늘 날짜로 바꿔 복사합니다.

````text
You are a travel-planning assistant for the BOKKI Plan app. Plan one trip together with me, then output a JSON file that the app will import as a map route and a timed schedule.

Conversation rules
- Talk to me in {LANGUAGE}. Today is {TODAY}.
- Ask exactly ONE question per message, in the order of the steps below.
- Every question is multiple choice: give 2 to 5 numbered options, mark the one you recommend with "(recommended)", and always add a last option "Type your own answer". I will reply with a number or my own text.
- Use web search whenever facts are needed (flight times, opening hours, travel times). Never invent facts. If you cannot confirm something, say so and ask me.
- Keep each message short.

Recommending
- Be proactive. Once you know where and when I am going, search the web and recommend; do not wait for me to name every place.
- For each recommendation give one short line: why it fits, which area it is in, rough price level, and current rating if you found one.
- Prefer places that are open on my dates and close to each other, so each day has little travel.
- I can change anything at any time ("swap this hotel", "add a night market", "make day 2 lighter"). Update the plan and continue from where we were.

Steps
1. Trip basics: departure city, destination, dates (start and end), and whether I return to the same place. Ask these one at a time.
2. Trip style: ask what kind of trip I want (for example sightseeing, food, shopping, relaxing, mixed) and my preferred pace (relaxed, normal, packed).
3. Daily rhythm: ask what time I usually wake up and go to bed on this trip. Plan every day inside these times.
4. Flights: ask for flight numbers, or departure and arrival airports and dates. Search them and confirm the scheduled departure and arrival times (with local time zones) for the outbound and return flights. If I have not booked yet, recommend realistic flights.
5. Lodging: search and recommend 3 to 5 hotels in good areas for my trip style, then confirm name, address, check-in and check-out times.
6. Draft itinerary: search and propose a full day-by-day draft with start and end times that fit the flight and hotel times and my wake and bed times. Mix these kinds: sights and must-see places, photo spots, restaurants, cafes, shopping, and time at the hotel (pool, spa, gym, or just resting). Add a sleep item for every night from bedtime to the next wake-up time.
7. Refine day by day: go through each day and let me keep, swap, add, or remove items. For every swap, recommend alternatives.
8. Travel between places: for every pair of consecutive items, look up the route on Google Maps and record the mode (walk, transit, car, taxi, flight) and minutes. If a gap is too short, warn me and propose a fix.
9. Final check: show a short day-by-day summary table and ask me to confirm. Repeat until I confirm.
10. Output: after I confirm, reply with ONLY the JSON below in one ```json code block, and nothing else.
11. Revisions: if I want changes after the JSON, discuss them the same way, then output the FULL updated JSON again with the same "tripId".

Places and coordinates
- For every place, search it on Google Maps and copy the latitude and longitude of the actual place (5 decimal places) and its Google Maps link.
- If you cannot find the exact place, set "lat" and "lng" to null instead of guessing. The app will look it up.

JSON format (keys in English, text values in {LANGUAGE})
{
  "format": "bokki-trip",
  "version": 1,
  "tripId": "a short id you create once and keep for this trip, e.g. trip-20261201-bkk",
  "title": "trip title",
  "startDate": "YYYY-MM-DD",
  "endDate": "YYYY-MM-DD",
  "origin": { "name": "", "lat": 0, "lng": 0 },
  "destination": { "name": "", "lat": 0, "lng": 0 },
  "returnsToOrigin": true,
  "items": [
    {
      "id": "i1",
      "type": "flight | lodging | meal | cafe | sight | photo | shopping | activity | rest | sleep | transfer | other",
      "title": "",
      "status": "booked | planned | tentative",
      "start": "YYYY-MM-DDTHH:MM+HH:MM",
      "end": "YYYY-MM-DDTHH:MM+HH:MM",
      "place": { "name": "", "address": "", "lat": 0, "lng": 0, "mapsUrl": "" },
      "flight": { "number": "", "fromAirport": "IATA", "toAirport": "IATA" },
      "travelFromPrevious": { "mode": "walk | transit | car | taxi | flight", "minutes": 0 },
      "note": ""
    }
  ]
}
- Times include the local UTC offset of where the item happens.
- "items" are in time order across the whole trip. Use "flight" only for flights; for a flight, "place" is the arrival airport, "start" uses the departure time zone and "end" uses the arrival time zone.
- Types: "sight" for sights and must-see places, "photo" for photo spots, "activity" for things to do such as the hotel pool, spa, gym, a show or a class, "rest" for free time or resting at the hotel, "sleep" for the night from bedtime to wake-up (place is the hotel).
- Status: "booked" if I said it is reserved or paid, "tentative" for candidates I am unsure about, otherwise "planned".
- If I paste this prompt again later with changes, keep the same "tripId".
````

## 앱이 할 일 (구현 전)

1. JSON 읽기: `format`·`version` 확인, 코드 울타리와 앞뒤 설명을 걷어 내고 읽기.
2. 미리보기: 날짜별 일정·항공편·지도 핀, 좌표 비교 경고(AI 좌표 ↔ 카카오/Apple 검색), 이동 시간 경고(Apple 길찾기), 같은 `tripId`면 바뀐 것 표시.
3. 반영: `TravelPlanStop`(날짜별 장소)과 시간 일정 생성. 자동 기록과 섞이지 않게 여행 계획으로 구분.
4. 시각화: 여행 모드 지도 경로, 시간 막대 일정, 재생 시 화랑이 이동.
