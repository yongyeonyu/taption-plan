// swift-tools-version: 6.0
import PackageDescription

// 가계부 값 타입과 정산 계산(ADR-005). 장부(`LedgerBook`)·화면·결제 문자 읽기는 앱에 있다. Foundation만 쓴다.
let package = Package(
    name: "TaptionLedgerCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18)
    ],
    products: [
        .library(name: "TaptionLedgerCore", targets: ["TaptionLedgerCore"])
    ],
    targets: [
        .target(name: "TaptionLedgerCore")
    ]
)
