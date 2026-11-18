// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokensAreRunningOut",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RunningOutCore", targets: ["RunningOutCore"]),
        .library(name: "RunningOutUI", targets: ["RunningOutUI"]),
        .executable(name: "running-out", targets: ["running-out"]),
        .executable(name: "TokensAreRunningOut", targets: ["TokensAreRunningOut"]),
    ],
    targets: [
        // pricing.json is embedded as Swift by scripts/embed-pricing.py, so no resource bundle is needed.
        .target(name: "RunningOutCore", exclude: ["Resources/pricing.json"]),
        .target(name: "RunningOutUI", dependencies: ["RunningOutCore"], resources: [.process("Resources")]),
        .executableTarget(name: "running-out", dependencies: ["RunningOutCore"]),
        .executableTarget(name: "TokensAreRunningOut", dependencies: ["RunningOutUI"]),
        // Renders each screen state to PNG for design review. Not shipped.
        .executableTarget(name: "ui-snapshots", dependencies: ["RunningOutUI"], path: "Tools/ui-snapshots"),
        .testTarget(name: "RunningOutCoreTests", dependencies: ["RunningOutCore"], exclude: ["Fixtures"]),
        .testTarget(name: "RunningOutUITests", dependencies: ["RunningOutUI"]),
    ]
)
