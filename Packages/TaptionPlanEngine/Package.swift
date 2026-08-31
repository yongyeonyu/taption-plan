// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionPlanEngine",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "TaptionPlanEngine", targets: ["TaptionPlanEngine"])],
    dependencies: [
        .package(path: "../TaptionPlanCore"),
        .package(path: "../TaptionActivityEngine"),
        .package(path: "../TaptionRouteEngine")
    ],
    targets: [
        .target(name: "TaptionPlanEngine", dependencies: [
            .product(name: "TaptionPlanCore", package: "TaptionPlanCore"),
            .product(name: "TaptionActivityEngine", package: "TaptionActivityEngine"),
            .product(name: "TaptionRouteEngine", package: "TaptionRouteEngine")
        ]),
        .testTarget(
            name: "TaptionPlanEngineTests",
            dependencies: ["TaptionPlanEngine"]
        )
    ]
)
