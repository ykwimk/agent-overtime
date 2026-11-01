// swift-tools-version:5.9
// Core logic and its tests. The app itself is built by AgentOvertime.xcodeproj,
// which compiles the same Core files into the app and the hook helper.
import PackageDescription

let package = Package(
    name: "AgentOvertime",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "fake-events", targets: ["fake-events"])],
    targets: [
        .target(name: "AgentOvertimeCore", path: "Sources/AgentOvertimeCore"),
        .executableTarget(name: "fake-events", dependencies: ["AgentOvertimeCore"], path: "tools/fake-events"),
        .testTarget(
            name: "AgentOvertimeCoreTests", dependencies: ["AgentOvertimeCore"], path: "Tests/AgentOvertimeCoreTests"),
    ],
    swiftLanguageVersions: [.v5]
)
