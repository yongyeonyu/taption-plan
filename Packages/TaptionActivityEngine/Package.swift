// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionActivityEngine",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "TaptionActivityEngine", targets: ["TaptionActivityEngine"])
    ],
    dependencies: [
        .package(path: "../TaptionPlanCore")
    ],
    targets: [
        .target(
            name: "TaptionActivityEngine",
            dependencies: [
                .product(name: "TaptionPlanCore", package: "TaptionPlanCore")
            ]
        ),
        .testTarget(
            name: "TaptionActivityEngineTests",
            dependencies: ["TaptionActivityEngine"]
        )
    ]
)
