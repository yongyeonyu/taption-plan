// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionPlanCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "TaptionPlanCore", targets: ["TaptionPlanCore"])
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite"
        ),
        .target(
            name: "TaptionPlanCore",
            dependencies: ["CSQLite"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TaptionPlanCoreTests",
            dependencies: ["TaptionPlanCore"]
        )
    ]
)
