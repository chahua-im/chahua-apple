// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ChahuaAPI",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ChahuaAPI", targets: ["ChahuaAPI"]),
    ],
    targets: [
        .target(name: "ChahuaAPI"),
        .testTarget(name: "ChahuaAPITests", dependencies: ["ChahuaAPI"]),
    ]
)
