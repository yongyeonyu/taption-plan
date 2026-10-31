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
    dependencies: [
        .package(path: "../TaptionClassifierEngine")
    ],
    targets: [
        .target(
            name: "TaptionActivityEngine",
            dependencies: [
                .product(name: "TaptionClassifierEngine", package: "TaptionClassifierEngine")
            ]
        ),
        .testTarget(
            name: "TaptionActivityEngineTests",
            dependencies: ["TaptionActivityEngine"]
        )
    ]
)
