// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "getGamen",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GetGamenCore", targets: ["GetGamenCore"]),
        .library(name: "GetGamenAutomation", targets: ["GetGamenAutomation"]),
        .executable(name: "getGamen", targets: ["GetGamen"]),
        .executable(name: "getGamenAutomation", targets: ["GetGamenAutomationHost"])
    ],
    targets: [
        .target(name: "GetGamenCore"),
        .target(name: "GetGamenAutomation", dependencies: ["GetGamenCore"]),
        .executableTarget(name: "GetGamen", dependencies: ["GetGamenCore"]),
        .executableTarget(name: "GetGamenAutomationHost", dependencies: ["GetGamenAutomation"]),
        .testTarget(name: "GetGamenAutomationTests", dependencies: ["GetGamenAutomation"]),
        .testTarget(name: "GetGamenCoreTests", dependencies: ["GetGamenCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "GetGamenAppTests", dependencies: ["GetGamen", "GetGamenCore"])
    ]
)
