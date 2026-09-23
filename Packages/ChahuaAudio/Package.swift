// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChahuaAudio",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ChahuaAudio", targets: ["ChahuaAudio"])],
    dependencies: [.package(url: "https://github.com/element-hq/swift-ogg.git", exact: "0.0.4")],
    targets: [
        .target(
            name: "ChahuaAudio", dependencies: [.product(name: "SwiftOGG", package: "swift-ogg")])
    ]
)
