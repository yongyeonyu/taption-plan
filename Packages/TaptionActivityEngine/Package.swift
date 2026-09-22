// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionActivityEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v13)
    ],
    products: [
        .library(name: "TaptionActivityEngine", targets: ["TaptionActivityEngine"])
    ],
    targets: [
        .target(
            name: "TaptionActivityEngine",
            dependencies: []
        ),
        .testTarget(
            name: "TaptionActivityEngineTests",
            dependencies: ["TaptionActivityEngine"]
        )
    ]
)
