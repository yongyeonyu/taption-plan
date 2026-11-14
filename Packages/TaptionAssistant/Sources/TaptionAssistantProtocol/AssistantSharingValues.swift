import Foundation

// 공유 수준·보관 기간 값. 등록부 동작의 읽기 쪽이 써서 Kit에서 내려왔다(RMN1114A25). 저장 키는 그대로다.

/// AI 비서에게 하루 기록을 얼마나 보낼지(AIR1110A01·TRP1110A06). 기기에만 두는 설정이다.
public enum AssistantShareLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case summary
    case visits

    public static let defaultsKey = "assistantShareLevel"

    public var id: String { rawValue }

    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .summary
    }

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    /// 덜 보내는 쪽으로 바꿨는가. 그러면 서버에 남은 더 자세한 날들을 지운다(REV1110A06).
    public static func isDowngrade(from old: Self, to new: Self) -> Bool { new.rank < old.rank }
}

/// 서버에 하루 기록을 남겨 둘 기간(TRP1110A07). 기본 7일.
public enum AssistantRetention: Int, CaseIterable, Identifiable, Sendable {
    case oneDay = 1
    case week = 7
    case month = 30

    public static let defaultsKey = "assistantRetentionDays"

    public var id: Int { rawValue }

    public static func current(_ defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.integer(forKey: defaultsKey)) ?? .week
    }
}
