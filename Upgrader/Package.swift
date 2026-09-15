// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WheelClickUpgrader",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UpgraderKit"),
        .executableTarget(name: "WheelClickUpgrader", dependencies: ["UpgraderKit"]),
        .testTarget(name: "UpgraderKitTests", dependencies: ["UpgraderKit"]),
    ],
    swiftLanguageVersions: [.v5]
)
