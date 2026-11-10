import Foundation

/// AI에 붙여 넣는 레퍼런스 프롬프트(TRP1110A01). 원문은 docs/TRIP_IMPORT.md와 같게 둔다.
enum TripImportPrompt {
    /// 「{LANGUAGE}」는 앱 언어의 영어 이름, 「{TODAY}」는 오늘 날짜로 바꾼다.
    static func text(languageCode: String, today: Date = .now) -> String {
        let languageName = Locale(identifier: "en").localizedString(forIdentifier: languageCode) ?? "English"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return template
            .replacingOccurrences(of: "{LANGUAGE}", with: languageName)
            .replacingOccurrences(of: "{TODAY}", with: formatter.string(from: today))
    }

    static var currentLanguageCode: String {
        MapHomeLanguage.current == .korean ? "ko" : UITextPack.activeLanguageCode ?? "en"
    }

    static let template = #"""
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
- If I paste this prompt again later with changes, keep the same "tripId".
"""#
}

/// 프롬프트를 채워 여는 AI 앱. 주소에 질문을 못 싣는 곳은 복사한 뒤 연다.
enum TripImportAIApp: String, CaseIterable, Identifiable {
    case chatGPT, claude, gemini

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }

    /// ChatGPT만 주소의 `q`로 질문을 채운다. 나머지는 붙여 넣는다.
    var prefillsPrompt: Bool { self == .chatGPT }

    /// `prompt`가 nil이면 질문 없이 연다. 연동 키가 든 프롬프트는 주소(방문 기록·서버 로그)에 싣지 않는다(REV1110A02).
    func url(prompt: String?) -> URL? {
        switch self {
        case .chatGPT:
            var components = URLComponents(string: "https://chatgpt.com/")
            if let prompt { components?.queryItems = [URLQueryItem(name: "q", value: prompt)] }
            return components?.url
        case .claude: return URL(string: "https://claude.ai/new")
        case .gemini: return URL(string: "https://gemini.google.com/app")
        }
    }
}
