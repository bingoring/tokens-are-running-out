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
        .target(name: "RunningOutCore"),
        .executableTarget(name: "running-out", dependencies: ["RunningOutCore"]),
        .testTarget(name: "RunningOutCoreTests", dependencies: ["RunningOutCore"]),
    ]
)
