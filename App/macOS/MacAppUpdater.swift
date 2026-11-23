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
        // Keep the key until display so changing the app language also refreshes command help.
        private let unavailabilityExplanation: String.LocalizationValue?

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
                    unavailabilityExplanation = "Updates are unavailable in this build."
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
                    unavailabilityExplanation =
                        "Updates are unavailable because this app’s update feed or signing key is not configured."
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
                unavailabilityExplanation = "Updates are unavailable in this build."
            #endif
        }

        var help: String {
            if let unavailabilityExplanation {
                return AppLanguage.localized(unavailabilityExplanation)
            }
            return canCheckForUpdates
                ? AppLanguage.localized("Check for Updates…")
                : AppLanguage.localized(
                    "Updates cannot be checked right now. Please try again shortly.")
        }

        func checkForUpdates() {
            guard canCheckForUpdates else { return }
            updaterController?.checkForUpdates(nil)
        }
    }

    struct MacAppUpdateCommands: Commands {
        @ObservedObject var updater: MacAppUpdater
        let language: AppLanguage

        var body: some Commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                    .help(updater.help)
                    // Commands do not inherit the window content's locale environment.
                    .environment(\.locale, language.locale)
            }
        }
    }
#endif
