// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrontAM",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "FrontAMCore", targets: ["FrontAMCore"]),
        .library(name: "FrontAMPlayer", targets: ["FrontAMPlayer"]),
        .library(name: "FrontAM", targets: ["FrontAM"]),
    ],
    targets: [
        .target(name: "FrontAMCore"),
        .target(
            name: "FrontAMPlayer",
            dependencies: ["FrontAMCore"],
            resources: [.process("Resources")]
        ),
        .target(name: "FrontAM", dependencies: ["FrontAMCore", "FrontAMPlayer"]),
    ],
    swiftLanguageModes: [.v6]
)
