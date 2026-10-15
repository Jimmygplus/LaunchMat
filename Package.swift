// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LaunchMat",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LaunchMatCore"),
        .executableTarget(name: "LaunchMat", dependencies: ["LaunchMatCore"]),
        .testTarget(name: "LaunchMatCoreTests", dependencies: ["LaunchMatCore"]),
    ]
)
