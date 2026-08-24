// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionPlanCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "TaptionPlanCore", targets: ["TaptionPlanCore"])
    ],
    targets: [
        .target(name: "TaptionPlanCore"),
        .testTarget(
            name: "TaptionPlanCoreTests",
            dependencies: ["TaptionPlanCore"]
        )
    ]
)
