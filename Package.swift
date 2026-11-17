// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TokensAreRunningOut",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RunningOutCore", targets: ["RunningOutCore"]),
        .executable(name: "running-out", targets: ["running-out"]),
    ],
    targets: [
        // pricing.json is embedded as Swift by scripts/embed-pricing.py, so no resource bundle is needed.
        .target(name: "RunningOutCore", exclude: ["Resources/pricing.json"]),
        .executableTarget(name: "running-out", dependencies: ["RunningOutCore"]),
        .testTarget(name: "RunningOutCoreTests", dependencies: ["RunningOutCore"]),
    ]
)
