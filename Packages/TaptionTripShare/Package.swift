// swift-tools-version: 6.0
import PackageDescription

// 여행 공유(TSH1114A26)의 기기 쪽 핵심. 규약의 정본은 `docs/TRIP_SHARE_PROTOCOL.md`.
// 앱 target·화면·저장소를 모른다. Foundation·CryptoKit·CommonCrypto만 쓰고, 서버 주소·키 보관·저장 위치는 앱이 넣어 준다.
let package = Package(
    name: "TaptionTripShare",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TaptionTripShare", targets: ["TaptionTripShare"]),
        // 시험용 가짜 서버(메모리 안의 방). 앱 시험에서도 쓸 수 있게 따로 둔다. 앱 본체에는 넣지 않는다.
        .library(name: "TaptionTripShareTesting", targets: ["TaptionTripShareTesting"])
    ],
    targets: [
        .target(name: "TaptionTripShare"),
        .target(name: "TaptionTripShareTesting", dependencies: ["TaptionTripShare"]),
        .testTarget(
            name: "TaptionTripShareTests",
            dependencies: ["TaptionTripShare", "TaptionTripShareTesting"],
            resources: [.copy("Fixtures")]
        )
    ]
)
