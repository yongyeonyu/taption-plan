// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionPlanStore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TaptionPlanStore", targets: ["TaptionPlanStore"])
    ],
    dependencies: [
        .package(path: "../TaptionPlanCore")
    ],
    targets: [
        .target(
            name: "TaptionPlanStore",
            dependencies: [.product(name: "TaptionPlanCore", package: "TaptionPlanCore")]
        ),
        .testTarget(
            name: "TaptionPlanStoreTests",
            dependencies: ["TaptionPlanStore"]
        )
    ]
)
