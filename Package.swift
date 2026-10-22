// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AIUsageTracker",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "UsageCore"),
        .executableTarget(name: "AIUsageTracker", dependencies: ["UsageCore"]),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
