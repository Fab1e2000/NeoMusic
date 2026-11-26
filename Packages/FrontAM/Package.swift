// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FrontAM",
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
        .target(name: "FrontAMCore"),
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
            ]
        ),
        .target(name: "FrontAMNavigation", dependencies: ["FrontAMCore", "FrontAMPopup"]),
        .target(name: "FrontAMPages", dependencies: ["FrontAMCore", "FrontAMNavigation"]),
        .target(name: "FrontAM", dependencies: ["FrontAMCore", "FrontAMPlayer", "FrontAMPopup", "FrontAMNavigation", "FrontAMPages"]),
    ],
    swiftLanguageModes: [.v6]
)
