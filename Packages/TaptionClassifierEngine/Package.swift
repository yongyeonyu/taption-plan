// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionClassifierEngine",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "TaptionClassifierEngine", targets: ["TaptionClassifierEngine"])
    ],
    targets: [
        .target(
            name: "TaptionClassifierEngine",
            dependencies: [],
            resources: [.process("Resources/record-classification.json")]
        ),
        .testTarget(
            name: "TaptionClassifierEngineTests",
            dependencies: ["TaptionClassifierEngine"]
        )
    ]
)
