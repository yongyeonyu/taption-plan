// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionClassifierEngine",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "TaptionClassifierEngine", targets: ["TaptionClassifierEngine"])
    ],
    dependencies: [
        .package(path: "../TaptionPlanCore")
    ],
    targets: [
        .target(
            name: "TaptionClassifierEngine",
            dependencies: [.product(name: "TaptionPlanCore", package: "TaptionPlanCore")]
        ),
        .testTarget(
            name: "TaptionClassifierEngineTests",
            dependencies: ["TaptionClassifierEngine"]
        )
    ]
)
