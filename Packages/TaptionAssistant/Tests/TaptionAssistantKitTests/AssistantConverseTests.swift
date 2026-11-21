import Foundation
import Testing
@testable import TaptionAssistantKit

/// AI1121A01: 앱 안 대화의 보내기 본문·지우기·답 읽기·길 고르기. 값은 모두 가짜다.
struct AssistantConverseTests {
    private let context = AssistantConverse.Context(today: "2026-11-21", timeZone: "+09:00", language: "ko", region: "가짜시 가짜구", tripID: "trip-1", tripTitle: "가짜 여행")

    private func object(_ data: Data?) throws -> [String: Any] {
        let data = try #require(data)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func bodyScrubsCoordinatesAndNumbersAndKeepsOnlyContextFields() throws {
        let body = try object(AssistantConverse.body([.init(role: .user, text: "12.34567, 23.45678 에서 카드 4111 1111 1111 1111로 12000원")], context: context))
        let text = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        #expect(!text.contains("12.3456") && !text.contains("4111 1111 1111"))
        #expect(text.contains("12000"))
        let sent = try #require(body["context"] as? [String: Any])
        #expect(Set(sent.keys) == ["today", "timeZone", "language", "region", "trip"])
    }

    @Test func bodyDropsLeadingAssistantTurnsAndNeedsAUserTurnLast() throws {
        let body = try object(AssistantConverse.body([.init(role: .assistant, text: "안녕하세요"), .init(role: .user, text: "내일 일정")], context: context))
        #expect((body["messages"] as? [[String: String]])?.map { $0["role"] } == ["user"])
        #expect(AssistantConverse.body([.init(role: .user, text: "a"), .init(role: .assistant, text: "b")], context: context) == nil)
    }

    @Test func contextNowFormatsDateAndOffset() {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        let seoul = AssistantConverse.Context.now(date, timeZone: TimeZone(identifier: "Asia/Seoul")!, language: "ko")
        #expect(seoul.timeZone == "+09:00")
        #expect(seoul.today.count == 10)
        #expect(AssistantConverse.Context.now(date, timeZone: TimeZone(identifier: "America/St_Johns")!, language: "en").timeZone.hasPrefix("-03:"))
    }

    @Test func decodeReadsReplyCommandsAndTrip() throws {
        let data = Data(#"{"reply":"넣을까요?","commands":[{"format":"bokki-command","version":1,"id":"ai-1","action":"addMemo","text":"우산"}],"trip":{"format":"bokki-trip","version":1,"tripId":"t","title":"가짜","items":[{"id":"i1"}]},"dropped":0,"redacted":["coordinates"],"truncated":false}"#.utf8)
        let reply = try AssistantConverse.decode(status: 200, data: data).get()
        #expect(reply.text == "넣을까요?")
        #expect(reply.commandCount == 1)
        #expect(reply.redacted == ["coordinates"])
        let envelope = try object(reply.commandsJSON)
        #expect((envelope["commands"] as? [[String: Any]])?.first?["action"] as? String == "addMemo")
        #expect(reply.tripJSON?.contains("bokki-trip") == true)
    }

    @Test func decodeMapsFailures() {
        #expect(AssistantConverse.decode(status: 429, data: Data(#"{"error":"daily_ai_limit","retryAfter":3600}"#.utf8)) == .failure(.limited(retryAfter: 3600, daily: true)))
        #expect(AssistantConverse.decode(status: 429, data: Data(#"{"error":"upstream_throttled","retryAfter":30}"#.utf8)) == .failure(.limited(retryAfter: 30, daily: false)))
        #expect(AssistantConverse.decode(status: 503, data: Data()) == .failure(.unavailable))
        #expect(AssistantConverse.decode(status: 400, data: Data()) == .failure(.rejected))
        #expect(AssistantConverse.decode(status: 502, data: Data()) == .failure(.server))
        #expect(AssistantConverse.decode(status: 200, data: Data("{}".utf8)) == .failure(.server))
    }

    @Test func intentFindsQuickMemosAndPolishOnlyOnTheFirstTurn() {
        #expect(AssistantConverseRouter.intent("메모: 우산 챙기기", isFirstTurn: true) == .quickMemo("우산 챙기기"))
        #expect(AssistantConverseRouter.intent("이거 다듬어 줘: 오늘 비옴 우산 없음", isFirstTurn: true) == .polish("오늘 비옴 우산 없음"))
        #expect(AssistantConverseRouter.intent("「오늘 비옴」 매끄럽게", isFirstTurn: true) == .polish("오늘 비옴"))
        #expect(AssistantConverseRouter.intent("메모: 우산", isFirstTurn: false) == .conversation)
        #expect(AssistantConverseRouter.intent("다음 주 부산 2박 3일 짜 줘", isFirstTurn: true) == .conversation)
    }

    @Test func routePrefersFreePathsAndKeepsCoordinatesOnDevice() {
        let cloud = AppleModelDecision(.privateCloud), device = AppleModelDecision(.onDevice), relay = AppleModelDecision(.relayQueue)
        let blocked = AppleModelDecision(.notAvailable, notice: .keepsCoordinates)
        #expect(AssistantConverseRouter.route(.quickMemo("a"), apple: nil, serverReady: false) == .local)
        #expect(AssistantConverseRouter.route(.polish("a"), apple: cloud, serverReady: true) == .apple)
        #expect(AssistantConverseRouter.route(.polish("a"), apple: device, serverReady: true) == .apple)
        #expect(AssistantConverseRouter.route(.polish("a"), apple: relay, serverReady: true) == .server)
        #expect(AssistantConverseRouter.route(.polish("a"), apple: relay, serverReady: false) == .unavailable)
        #expect(AssistantConverseRouter.route(.polish("a"), apple: blocked, serverReady: true) == .unavailable)
        #expect(AssistantConverseRouter.route(.conversation, apple: cloud, serverReady: true) == .server)
        #expect(AssistantConverseRouter.route(.conversation, apple: cloud, serverReady: false) == .unavailable)
    }
}
