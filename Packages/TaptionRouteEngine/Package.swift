// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionRouteEngine",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TaptionRouteEngine", targets: ["TaptionRouteEngine"])
    ],
    dependencies: [
        .package(path: "../TaptionPlanCore")
    ],
    targets: [
        .target(
            name: "TaptionRouteEngine",
            dependencies: [
                .product(name: "TaptionPlanCore", package: "TaptionPlanCore")
            ]
        ),
        .testTarget(
            name: "TaptionRouteEngineTests",
            dependencies: ["TaptionRouteEngine"]
        )
    ]
)
