// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChahuaMediaCache",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "ChahuaMediaCache", targets: ["ChahuaMediaCache"]),
    ],
    targets: [
        .target(name: "ChahuaMediaCache"),
        .testTarget(name: "ChahuaMediaCacheTests", dependencies: ["ChahuaMediaCache"]),
    ],
    swiftLanguageModes: [.v6]
)
