import CoreFoundation
import CryptoKit
import Foundation

private struct ValidationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ValidationFailure(description: message) }
}

private func environment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw ValidationFailure(description: "Missing environment variable " + name)
    }
    return value
}

private func string(_ info: [String: Any], _ name: String) throws -> String {
    guard let value = info[name] as? String, !value.isEmpty else {
        throw ValidationFailure(description: "Missing or invalid app Info.plist string " + name)
    }
    return value
}

private func verifyBoolean(_ info: [String: Any], _ name: String) throws {
    guard let value = info[name] as? NSNumber,
        CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue
    else {
        throw ValidationFailure(description: "App Info.plist requires boolean true for " + name)
    }
}

private func publicKey(_ info: [String: Any]) throws -> Curve25519.Signing.PublicKey {
    let encoded = try string(info, "SUPublicEDKey")
    guard let data = Data(base64Encoded: encoded), data.count == 32 else {
        throw ValidationFailure(
            description: "App SUPublicEDKey is not a 32-byte base64 Ed25519 public key")
    }
    return try Curve25519.Signing.PublicKey(rawRepresentation: data)
}

private func validate() throws {
    let infoData = try Data(
        contentsOf: URL(fileURLWithPath: "build/notarized/Chahua.app/Contents/Info.plist"))
    guard
        let info = try PropertyListSerialization.propertyList(from: infoData, format: nil)
            as? [String: Any]
    else {
        throw ValidationFailure(description: "App Info.plist is not a dictionary")
    }
    let version = try environment("APPLE_BUNDLE_VERSION")
    let selectedBuild = try environment("SELECTED_APPLE_BUILD")
    try require(
        version == selectedBuild,
        "Bundle version must be the selected Apple build, not the deployment build")
    try require(
        try string(info, "CFBundleVersion") == version,
        "App CFBundleVersion does not match selected artifact metadata")
    try require(
        try string(info, "CFBundleIdentifier") == "app.chahua.chat",
        "Unexpected app bundle identifier")

    switch CommandLine.arguments.dropFirst().first {
    case "bundle":
        try require(
            try string(info, "SUFeedURL")
                == "https://jenkins.codetector.org/job/chahua/job/deploy/job/macos-notarize/lastSuccessfulBuild/artifact/build/artifacts/appcast.xml",
            "App SUFeedURL does not match the Jenkins release feed"
        )
        try require(
            try string(info, "SUPublicEDKey") == "BlBCwxhJo3KmPVOEEiKlY1qQiKMdAeuj5xUifRoCYUM=",
            "App SUPublicEDKey does not match the release signing public key"
        )
        try verifyBoolean(info, "SUVerifyUpdateBeforeExtraction")
        try verifyBoolean(info, "SUEnableInstallerLauncherService")
    case "key":
        let expectedKey = try publicKey(info)
        let keyPath = try environment("SPARKLE_ED_KEY_FILE")
        let encoded = try String(contentsOfFile: keyPath, encoding: .utf8).trimmingCharacters(
            in: .whitespacesAndNewlines)
        // Sparkle 2.10.1 generate_keys exports a base64 32-byte Ed25519 seed.
        // Derivation is in memory via CryptoKit; no Keychain import or key copy.
        guard let seed = Data(base64Encoded: encoded), seed.count == 32 else {
            throw ValidationFailure(
                description:
                    "Sparkle credential must contain a base64 32-byte Ed25519 seed exported by generate_keys"
            )
        }
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        try require(
            signingKey.publicKey.rawRepresentation == expectedKey.rawRepresentation,
            "Sparkle credential does not match the app's embedded SUPublicEDKey"
        )
        let names = try FileManager.default.contentsOfDirectory(atPath: "build/artifacts")
        let allowed: Set<String> = ["Chahua-macOS-notarized.zip", "apple-artifact-metadata.json"]
        try require(
            Set(names).isSubset(of: allowed),
            "Only the final notarized ZIP and source metadata may be present before appcast generation"
        )
        try require(names.contains("Chahua-macOS-notarized.zip"), "Missing final notarized ZIP")
    case "appcast":
        let namespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        let document = try XMLDocument(
            contentsOf: URL(fileURLWithPath: "build/artifacts/appcast.xml"),
            options: .nodeLoadExternalEntitiesNever
        )
        let items = try document.nodes(forXPath: "/rss/channel/item")
        let enclosures = try document.nodes(forXPath: "//enclosure")
        try require(
            items.count == 1 && enclosures.count == 1,
            "Appcast must contain exactly one release and one full enclosure, with no deltas")
        guard let item = items.first as? XMLElement,
            let enclosure = enclosures.first as? XMLElement,
            enclosure.parent === item
        else {
            throw ValidationFailure(
                description: "Appcast enclosure is not attached to its release item")
        }
        let versions = item.elements(forLocalName: "version", uri: namespace)
        try require(
            versions.count == 1 && versions[0].stringValue == version,
            "Appcast version does not match selected Apple CFBundleVersion")
        let shortVersions = item.elements(forLocalName: "shortVersionString", uri: namespace)
        try require(
            shortVersions.count == 1
                && shortVersions[0].stringValue == (try string(info, "CFBundleShortVersionString")),
            "Appcast marketing version does not match the app"
        )
        let expectedURL =
            try environment("BUILD_URL") + "artifact/build/artifacts/Chahua-macOS-notarized.zip"
        try require(
            enclosure.attribute(forName: "url")?.stringValue == expectedURL,
            "Appcast enclosure does not reference the exact final ZIP's immutable Jenkins URL")
        let zip = try Data(
            contentsOf: URL(fileURLWithPath: "build/artifacts/Chahua-macOS-notarized.zip"),
            options: .mappedIfSafe)
        try require(
            enclosure.attribute(forName: "length")?.stringValue == String(zip.count),
            "Appcast enclosure length does not match final ZIP")
        guard
            let encodedSignature = enclosure.attribute(forLocalName: "edSignature", uri: namespace)?
                .stringValue,
            let signature = Data(base64Encoded: encodedSignature), signature.count == 64
        else {
            throw ValidationFailure(
                description: "Appcast enclosure is missing a valid Ed25519 signature")
        }
        try require(
            try publicKey(info).isValidSignature(signature, for: zip),
            "Appcast signature is invalid for the final ZIP and app public key")
    default:
        throw ValidationFailure(description: "Expected bundle, key, or appcast validation mode")
    }
}

do {
    try validate()
} catch {
    fputs("macOS release validation failed: " + String(describing: error) + "\n", stderr)
    exit(1)
}
