// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BigBang",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BigBangCore", targets: ["BigBangCore"]),
        .library(name: "BigBangNetworking", targets: ["BigBangNetworking"]),
        .library(name: "BigBangSelection", targets: ["BigBangSelection"]),
        .executable(name: "BigBangFixture", targets: ["BigBangFixture"])
    ],
    dependencies: [.package(url: "https://github.com/MacPaw/OpenAI.git", exact: "0.5.2")],
    targets: [
        .target(name: "BigBangCore", resources: [.process("Resources")]),
        .target(name: "BigBangSelection", dependencies: ["BigBangCore"]),
        .target(name: "BigBangNetworking", dependencies: ["BigBangCore", .product(name: "OpenAI", package: "OpenAI")]),
        .target(name: "BigBangTestSupport", path: "Tests/Support"),
        .executableTarget(name: "BigBangFixture", dependencies: ["BigBangTestSupport"], path: "Tests/FixtureRunner"),
        .testTarget(name: "BigBangCoreTests", dependencies: ["BigBangCore"]),
        .testTarget(name: "BigBangSelectionTests", dependencies: ["BigBangSelection", "BigBangCore"]),
        .testTarget(name: "BigBangNetworkingTests", dependencies: ["BigBangNetworking", "BigBangCore", "BigBangTestSupport"])
    ]
)
