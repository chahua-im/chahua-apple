// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChahuaMarkdown",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ChahuaMarkdown", targets: ["ChahuaMarkdown"])],
    targets: [
        .target(name: "ChahuaMarkdown", resources: [.copy("Resources")]),
        .testTarget(name: "ChahuaMarkdownTests", dependencies: ["ChahuaMarkdown"]),
    ],
    swiftLanguageModes: [.v6]
)
