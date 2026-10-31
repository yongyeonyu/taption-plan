// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionWatchSync",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .watchOS(.v11)
    ],
    products: [
        .library(name: "TaptionWatchSync", targets: ["TaptionWatchSync"]),
        .library(name: "TaptionWatchBehaviorML", targets: ["TaptionWatchBehaviorML"])
    ],
    dependencies: [
        .package(path: "../TaptionPlanCore")
    ],
    targets: [
        .target(
            name: "TaptionWatchSync",
            dependencies: [.product(name: "TaptionPlanCore", package: "TaptionPlanCore")]
        ),
        .target(
            name: "TaptionWatchBehaviorML",
            dependencies: ["TaptionWatchSync"]
        ),
        .testTarget(
            name: "TaptionWatchSyncTests",
            dependencies: ["TaptionWatchSync"]
        )
    ]
)
