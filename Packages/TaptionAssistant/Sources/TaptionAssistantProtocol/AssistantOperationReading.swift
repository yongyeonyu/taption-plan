import Foundation
import TaptionWatchSync

// 동작 등록부(ACT1114A07)의 읽기 쪽. 적용(`AssistantOperation.apply`)과 등록부 목록은 앱에 있다.

/// 동작 하나의 이름표. 서버 등록부와 `name`·`fields`가 같아야 한다.
public struct AssistantOperationSpec: Sendable {
    /// 「AI 비서 요청을 반영했어요」 알림에서 어느 수에 더할지.
    public enum Counter: Sendable { case memos, schedules, edits, settings, ledger }

    public var name: String
    public var fields: [String]
    public var counter: Counter
    /// 지우는 동작. 「AI가 할 수 있는 일」의 「지우는 일」 묶음에 보인다.
    public var deletes = false
    /// 사용자가 켜기 전에는 꺼져 있는 동작(ACT1114A09: 백업에서 복원).
    public var startsOff = false
    /// 바꾸는 기존 항목 수(20개 확인 규칙). 새로 더하기만 하면 0.
    public var changes = 1
    public var title: @Sendable (AppLanguagePreference.ResolvedLanguage) -> String
    /// 연결 안내의 한 줄: 동작 이름 뒤에 오는 칸 보기와 설명.
    public var guide: String

    public init(
        name: String, fields: [String], counter: Counter, deletes: Bool = false, startsOff: Bool = false, changes: Int = 1,
        title: @escaping @Sendable (AppLanguagePreference.ResolvedLanguage) -> String, guide: String
    ) {
        self.name = name
        self.fields = fields
        self.counter = counter
        self.deletes = deletes
        self.startsOff = startsOff
        self.changes = changes
        self.title = title
        self.guide = guide
    }
}

/// 등록부 동작의 읽기 쪽. 읽기(`init?`)에서 서버와 같은 규칙으로 다시 본다. 앱 모델을 모른다.
public protocol AssistantOperationReading: Sendable {
    static var spec: AssistantOperationSpec { get }
    init?(fields: AssistantFields)
    var changeCount: Int { get }
}

extension AssistantOperationReading {
    public var changeCount: Int { Self.spec.changes }
}

/// 읽어 낸 동작. 같은 이름·같은 칸이면 같은 명령이다.
public struct AssistantParsedOperation: Equatable, Sendable {
    public let name: String
    public let values: [String: AssistantJSON]
    public let operation: any AssistantOperationReading

    public init(name: String, values: [String: AssistantJSON], operation: any AssistantOperationReading) {
        self.name = name
        self.values = values
        self.operation = operation
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name && lhs.values == rhs.values }
}
