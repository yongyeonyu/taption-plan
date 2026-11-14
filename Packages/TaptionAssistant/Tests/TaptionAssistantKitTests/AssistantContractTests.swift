import Foundation
import XCTest
@testable import TaptionAssistantKit

/// 기존 설치와의 약속(PKG1114A19). 기기 설정 키·요청 모양·서버 회신 읽기는 코드를 옮겨도 그대로여야 한다.
/// 키체인 자리는 앱 시험(`AssistantRelayTests`)이 시뮬레이터에서 본다.
final class AssistantContractTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "AssistantContractTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testStoredKeysAreUnchanged() {
        XCTAssertEqual(
            [AssistantRegistration.registeredKey, AssistantRegistration.searchRegisteredKey, AssistantRegistration.rotationKey,
             AssistantRegistration.rotationTag, AssistantRegistration.reconnectKey, AssistantPINStore.setKey],
            ["assistantRegisteredMasterID", "assistantRegisteredSearchID", "assistantMasterRotation", "SEC1110A02", "assistantNeedsReconnect", "assistantPINSet"]
        )
        XCTAssertEqual(
            [AssistantKeyLabels.labelsKey, AssistantKeyLabels.periodsKey, AssistantKeyLabels.serverCountKey, AssistantKeyLabels.clientsKey,
             AssistantKeyProviders.defaultsKey, AssistantShareLevel.defaultsKey, AssistantRetention.defaultsKey],
            ["assistantKeyLabels", "assistantKeyPeriods", "assistantServerKeyCount", "assistantKeyClients", "assistantKeyProviders",
             "assistantShareLevel", "assistantRetentionDays"]
        )
        XCTAssertEqual(
            [AssistantActivityUploadGate.defaultsKey, AssistantActivityFlags.sharedKey, AssistantActivityFlags.pendingClearKey,
             AssistantCommandLedger.defaultsKey],
            ["assistantActivityHashes", "assistantActivityShared", "assistantActivityPendingClear", "assistantCommandHandledIDs"]
        )
        XCTAssertEqual(
            [AITaskQueue.uploadsKey, AITaskQueue.cacheKey, AITaskQueue.ackedKey, AITaskQueue.finishedSeenKey,
             AssistantQuestionStore.key, AssistantQuestionStore.dirtyKey],
            ["aiTaskUploads", "aiTaskCache", "aiTaskAcked", "aiTaskFinishedSeen", "assistantQuestions", "assistantQuestionsDirty"]
        )
        XCTAssertEqual(AssistantQuestionNotice.identifier("q1"), "assistant-question-q1")
        XCTAssertEqual(TripRelay.rotationDeletionPaths, ["/keys", "/activity", "/command", "/plan"])
        XCTAssertEqual(AssistantKeyStore.keyID("abc"), "ba7816bf")
        XCTAssertEqual(AssistantShareLevel.allCases.map(\.rawValue), ["off", "summary", "visits"])
        XCTAssertEqual(AssistantRetention.allCases.map(\.rawValue), [1, 7, 30])
    }

    func testRelayRequestShape() throws {
        let client = AssistantClientState(level: .summary, debug: true, locked: false)
        let body = Data(#"{"a":1}"#.utf8)
        let request = try XCTUnwrap(TripRelay.relayRequest(
            "/rules", method: "POST", query: [URLQueryItem(name: "since", value: "3")], body: body, token: "KEY", host: "relay.example.com", client: client
        ))
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example.com/rules?since=3")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.httpBody, body)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer KEY")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(TripRelay.clientHeaderName, "x-bokki-client")
        XCTAssertEqual(
            TripRelay.clientHeader(model: "iPhone12,3", build: "341", level: client.level, debug: client.debug, locked: client.locked),
            "iPhone12,3;341;summary;debug"
        )
        XCTAssertEqual(TripRelay.clientHeader(model: "iPhone12,3", build: "341", level: .off, debug: false, locked: true), "iPhone12,3;341;off;locked")
        XCTAssertNil(TripRelay.relayRequest("/keys", method: "GET", token: "KEY", host: nil, client: client))
        XCTAssertEqual(TripRelay.isoText(Date(timeIntervalSince1970: 1_800_000_000)), "2027-01-15T08:00:00Z")
    }

    func testShareLevelAndRetentionReadDefaults() {
        let store = defaults()
        XCTAssertEqual(AssistantShareLevel.current(store), .summary)
        XCTAssertEqual(AssistantRetention.current(store), .week)
        store.set("visits", forKey: "assistantShareLevel")
        store.set(30, forKey: "assistantRetentionDays")
        XCTAssertEqual(AssistantShareLevel.current(store), .visits)
        XCTAssertEqual(AssistantRetention.current(store), .month)
        XCTAssertTrue(AssistantShareLevel.isDowngrade(from: .visits, to: .summary))
        XCTAssertFalse(AssistantShareLevel.isDowngrade(from: .off, to: .summary))
    }

    func testServerRefusalReading() {
        func kind(_ status: Int, _ json: String) -> AssistantServerRefusal.Kind? {
            AssistantServerRefusal.parse(status: status, data: Data(json.utf8))?.kind
        }
        XCTAssertEqual(kind(403, #"{"error":"wrong_pin","remaining":2}"#), .wrongPIN)
        XCTAssertEqual(kind(423, #"{"error":"locked","retryAfter":60}"#), .locked)
        XCTAssertEqual(kind(404, #"{"error":"not_found"}"#), .serverOutdated)
        XCTAssertEqual(kind(401, "{}"), .unauthorized)
        XCTAssertEqual(kind(422, #"{"error":"too_many_keys"}"#), .tooManyKeys)
        XCTAssertEqual(kind(429, "{}"), .rateLimited)
        XCTAssertNil(kind(500, "{}"))
        XCTAssertEqual(AssistantServerRefusal.parse(status: 403, data: Data(#"{"error":"wrong_pin","remaining":2}"#.utf8))?.remaining, 2)
    }

    func testHandledCommandIDsKeepTheLatest() {
        let store = defaults()
        AssistantCommandLedger.remember(["a", "b"], defaults: store)
        AssistantCommandLedger.remember(["a"], defaults: store)
        XCTAssertEqual(store.stringArray(forKey: "assistantCommandHandledIDs"), ["b", "a"])
        AssistantCommandLedger.forget(["b"], defaults: store)
        XCTAssertEqual(AssistantCommandLedger.handled(store), ["a"])
    }

    @MainActor
    func testTaskQueueStoresUploadsAndAcknowledges() {
        let store = defaults()
        AITaskQueue.save([AITaskQueue.Upload(id: "t1", kind: .paymentText, text: "x"), AITaskQueue.Upload(id: "t2", kind: .other, text: "y")], store)
        XCTAssertEqual(AITaskQueue.unsent(store).map(\.id), ["t1", "t2"])
        AITaskQueue.acknowledge(["t1"], defaults: store)
        XCTAssertEqual(AITaskQueue.pendingUploads(store).map(\.id), ["t2"])
        XCTAssertEqual(store.stringArray(forKey: "aiTaskAcked"), ["t1"])
        let list = AITaskQueue.decodeList(Data(#"{"tasks":[{"id":"a","kind":"payment_text","status":"done"},{"id":"b","kind":"new_kind","status":"later"},{"kind":1}]}"#.utf8))
        XCTAssertEqual(list.map(\.id), ["a", "b"])
        XCTAssertEqual(list.map(\.kind), [.paymentText, .other])
        XCTAssertEqual(list.map(\.status), [.done, .unknown])
    }
}
