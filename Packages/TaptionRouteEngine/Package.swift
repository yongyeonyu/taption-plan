// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionRouteEngine",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [
        .library(name: "TaptionRouteEngine", targets: ["TaptionRouteEngine"])
    ],
    targets: [
        .target(
            name: "TaptionRouteEngine",
            dependencies: [],
            resources: [.process("Travel/Resources")]
        ),
        .testTarget(
            name: "TaptionRouteEngineTests",
            dependencies: ["TaptionRouteEngine"]
        )
    ]
)
