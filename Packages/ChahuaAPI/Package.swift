// swift-tools-version: 6.0

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
    ],
    swiftLanguageModes: [.v6],
)
