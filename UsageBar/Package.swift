// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "UsageBar", targets: ["UsageBar"]),
        .executable(name: "UsageBarProbe", targets: ["UsageBarProbe"]),
    ],
    targets: [
        .target(name: "UsageBarCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageBarCore"]),
        .executableTarget(name: "UsageBarProbe", dependencies: ["UsageBarCore"]),
        .testTarget(name: "UsageBarCoreTests", dependencies: ["UsageBarCore"]),
    ])
