import Foundation

public protocol TaptionPlanAppGroupProviding: Sendable {
    var identifier: String { get }
}

public struct FixedTaptionPlanAppGroupProvider: TaptionPlanAppGroupProviding {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public enum TaptionPlanSharedContainer {
    public static let defaultAppGroupIdentifier = "group.com.taption.plan"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (any TaptionPlanAppGroupProviding)?

    public static var appGroupIdentifier: String {
        lock.lock()
        defer { lock.unlock() }
        return provider?.identifier ?? defaultAppGroupIdentifier
    }

    public static func configure(provider: any TaptionPlanAppGroupProviding) {
        guard !provider.identifier.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        self.provider = provider
    }

    public static func resetProvider() {
        lock.lock()
        defer { lock.unlock() }
        provider = nil
    }

    public static func containerURL(
        fileManager: FileManager = .default
    ) -> URL? {
        fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }
}

public enum TaptionPlanDeviceLocalStorage {
    public static func excludeFromBackup(
        fileManager: FileManager = .default
    ) {
        var roots: [URL] = []
        if let group = TaptionPlanSharedContainer.containerURL(
            fileManager: fileManager
        ) {
            roots.append(group)
        }
        if let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TaptionPlan", isDirectory: true) {
            try? fileManager.createDirectory(
                at: applicationSupport,
                withIntermediateDirectories: true
            )
            roots.append(applicationSupport)
        }
        for var root in roots {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? root.setResourceValues(values)
        }
    }
}
