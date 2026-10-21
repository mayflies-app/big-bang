// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BigBang",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BigBangCore", targets: ["BigBangCore"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "BigBangCore", resources: [.process("Resources")]),
        .testTarget(name: "BigBangCoreTests", dependencies: ["BigBangCore"]),
    ]
)
