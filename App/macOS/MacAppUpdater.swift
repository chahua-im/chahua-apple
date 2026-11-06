#if os(macOS)
    import Combine
    import Foundation
    import Sparkle
    import SwiftUI
    import os

    @MainActor
    final class MacAppUpdater: ObservableObject {
        @Published private(set) var canCheckForUpdates = false

        private let updaterController: SPUStandardUpdaterController?
        private let unavailabilityExplanation: String?

        init(productionServicesEnabled: Bool) {
            #if CHAHUA_SELF_UPDATE
                let process = ProcessInfo.processInfo
                let fixtureArguments = [
                    "-fixture-gallery", "-bubble-timeline", "-message-status-preview",
                ]
                guard productionServicesEnabled,
                    process.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1",
                    !fixtureArguments.contains(where: process.arguments.contains),
                    NSClassFromString("XCTestCase") == nil
                else {
                    updaterController = nil
                    unavailabilityExplanation = String(
                        localized: "Updates are unavailable in this build.")
                    return
                }

                let bundle = Bundle.main
                guard
                    let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                    !feed.contains("$("),
                    let feedComponents = URLComponents(string: feed),
                    feedComponents.scheme?.lowercased() == "https",
                    let host = feedComponents.host, !host.isEmpty,
                    feedComponents.user == nil, feedComponents.password == nil,
                    feedComponents.url != nil,
                    let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
                    let keyData = Data(base64Encoded: publicKey), keyData.count == 32
                else {
                    updaterController = nil
                    unavailabilityExplanation = String(
                        localized:
                            "Updates are unavailable because this app’s update feed or signing key is not configured."
                    )
                    Logger(subsystem: "app.chahua.chat", category: "updater").error(
                        "Self-update is disabled: SUFeedURL must be an HTTPS URL and SUPublicEDKey must be a base64-encoded 32-byte Ed25519 public key."
                    )
                    return
                }

                // Sparkle's macOS-only standard AppKit UI owns update permission,
                // progress, installation, and relaunch prompts. SwiftUI has no equivalent
                // update flow; using the standard driver preserves Sparkle's user choices.
                let controller = SPUStandardUpdaterController(
                    startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
                updaterController = controller
                unavailabilityExplanation = nil
                controller.updater.publisher(for: \.canCheckForUpdates)
                    .assign(to: &$canCheckForUpdates)
            #else
                updaterController = nil
                unavailabilityExplanation = String(
                    localized: "Updates are unavailable in this build.")
            #endif
        }

        var help: String {
            if let unavailabilityExplanation {
                return unavailabilityExplanation
            }
            return canCheckForUpdates
                ? String(localized: "Check for Updates…")
                : String(
                    localized: "Updates cannot be checked right now. Please try again shortly.")
        }

        func checkForUpdates() {
            guard canCheckForUpdates else { return }
            updaterController?.checkForUpdates(nil)
        }
    }

    struct MacAppUpdateCommands: Commands {
        @ObservedObject var updater: MacAppUpdater

        var body: some Commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                    .help(updater.help)
            }
        }
    }
#endif
