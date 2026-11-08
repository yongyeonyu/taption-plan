// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaptionPlanStore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TaptionPlanStore", targets: ["TaptionPlanStore"])
    ],
    dependencies: [
        .package(path: "../TaptionPlanCore"),
        .package(path: "../TaptionWatchSync")
    ],
    targets: [
        .target(
            name: "TaptionPlanStore",
            dependencies: [
                .product(name: "TaptionPlanCore", package: "TaptionPlanCore"),
                // 저장 설정(`AppFeatureSettings`)이 Watch 프로필과 언어 선택 값을 담는다.
                .product(name: "TaptionWatchSync", package: "TaptionWatchSync")
            ]
        ),
        .testTarget(
            name: "TaptionPlanStoreTests",
            dependencies: ["TaptionPlanStore"]
        )
    ]
)
