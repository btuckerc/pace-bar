// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PaceBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PaceBar", targets: ["PaceBar"]),
        .executable(name: "PaceBarProbe", targets: ["PaceBarProbe"]),
    ],
    targets: [
        .target(name: "PaceBarCore"),
        .executableTarget(name: "PaceBar", dependencies: ["PaceBarCore"]),
        .executableTarget(name: "PaceBarProbe", dependencies: ["PaceBarCore"]),
        .testTarget(name: "PaceBarCoreTests", dependencies: ["PaceBarCore"]),
    ])
