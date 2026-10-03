public enum TaptionWatchHealthLaunchPolicy {
    public enum Action: Equatable, Sendable {
        case none, requestAuthorization, refresh
    }

    public static func action(
        isPaired: Bool,
        healthEnabled: Bool,
        hasRequestedAuthorization: Bool
    ) -> Action {
        if healthEnabled { return .refresh }
        if isPaired && !hasRequestedAuthorization { return .requestAuthorization }
        return .none
    }
}
