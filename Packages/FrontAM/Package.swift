// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrontAM",
    defaultLocalization: "zh-Hans",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "FrontAMCore", targets: ["FrontAMCore"]),
        .library(name: "FrontAMPlayer", targets: ["FrontAMPlayer"]),
        .library(name: "FrontAMPopup", targets: ["FrontAMPopup"]),
        .library(name: "FrontAMNavigation", targets: ["FrontAMNavigation"]),
        .library(name: "FrontAMPages", targets: ["FrontAMPages"]),
        .library(name: "FrontAM", targets: ["FrontAM"]),
    ],
    dependencies: [.package(path: "Vendor/LNPopupUI")],
    targets: [
        .target(name: "FrontAMCore", resources: [.process("Resources")]),
        .target(
            name: "FrontAMPlayer",
            dependencies: ["FrontAMCore"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "FrontAMPopup",
            dependencies: [
                "FrontAMCore",
                "FrontAMPlayer",
                .product(name: "LNPopupUI-Static", package: "LNPopupUI"),
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "FrontAMNavigation", dependencies: ["FrontAMCore"], resources: [.process("Resources")]),
        .target(name: "FrontAMPages", dependencies: ["FrontAMCore", "FrontAMNavigation"], resources: [.process("Resources")]),
        .target(name: "FrontAM", dependencies: ["FrontAMCore", "FrontAMPlayer", "FrontAMPopup", "FrontAMNavigation", "FrontAMPages"]),
        .testTarget(name: "FrontAMCoreTests", dependencies: ["FrontAMCore"]),
        .testTarget(name: "FrontAMNavigationTests", dependencies: ["FrontAMNavigation"]),
        .testTarget(name: "FrontAMPagesTests", dependencies: ["FrontAMPages"]),
        .testTarget(name: "FrontAMPlayerTests", dependencies: ["FrontAMPlayer"]),
    ],
    swiftLanguageModes: [.v6]
)
