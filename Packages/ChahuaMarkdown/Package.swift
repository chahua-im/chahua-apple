// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ChahuaMarkdown",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ChahuaMarkdown", targets: ["ChahuaMarkdown"])],
    targets: [
        // A root-level Resources directory makes iOS resource bundles ambiguous to codesign.
        .target(name: "ChahuaMarkdown", resources: [.process("Resources")]),
        .testTarget(name: "ChahuaMarkdownTests", dependencies: ["ChahuaMarkdown"]),
    ],
    swiftLanguageModes: [.v6]
)
