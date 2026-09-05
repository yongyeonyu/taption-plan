import Foundation

public enum TaptionPlanSharedContainer {
    public static let appGroupIdentifier = "group.com.taption.plan"
}

public enum TaptionPlanDeviceLocalStorage {
    public static func excludeFromBackup(
        fileManager: FileManager = .default
    ) {
        var roots: [URL] = []
        if let group = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier:
                TaptionPlanSharedContainer.appGroupIdentifier
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
