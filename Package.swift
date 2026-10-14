// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LaunchGrid",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LaunchGridCore"),
        .executableTarget(name: "LaunchGrid", dependencies: ["LaunchGridCore"]),
        .testTarget(name: "LaunchGridCoreTests", dependencies: ["LaunchGridCore"]),
    ]
)
