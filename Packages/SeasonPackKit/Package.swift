// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SeasonPackKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "SeasonPackKit", targets: ["SeasonPackKit"])
    ],
    targets: [
        .target(
            name: "SeasonPackKit",
            resources: [.copy("Resources/seed"), .copy("Resources/seed-debug")]
        ),
        .testTarget(
            name: "SeasonPackKitTests",
            dependencies: ["SeasonPackKit"]
        )
    ]
)
