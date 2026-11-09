// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "threshold",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "threshold", targets: ["threshold"]),
        .library(name: "ThresholdCore", targets: ["ThresholdCore"])
    ],
    targets: [
        .target(name: "ThresholdCore"),
        .executableTarget(name: "threshold", dependencies: ["ThresholdCore"]),
        .testTarget(name: "ThresholdCoreTests", dependencies: ["ThresholdCore"])
    ],
    swiftLanguageModes: [.v5]
)
