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
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "ChahuaAPI", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ChahuaAPITests", dependencies: ["ChahuaAPI"]),
    ],
    swiftLanguageModes: [.v6],
)
