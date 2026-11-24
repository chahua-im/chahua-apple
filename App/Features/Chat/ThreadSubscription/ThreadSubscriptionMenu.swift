import ChahuaAPI
import SwiftUI

/// Subscription control in the thread title bar. The header owns its glass:
/// a shared action capsule on desktop, a circular touch target on iPhone/iPad.
///
/// Unsubscribed threads show a bell that subscribes in one tap. Subscribed
/// threads show an archive box: outlined archives after confirmation, filled
/// (archived) unarchives.
struct ThreadSubscriptionMenu: View {
    @ObservedObject var model: ThreadSubscriptionModel
    @State private var confirmsArchive = false
    @Environment(\.isWideChatLayout) private var isWideChatLayout

    private var usesDesktopChrome: Bool {
        #if os(macOS)
            isWideChatLayout
        #else
            false
        #endif
    }

    private var statusLabel: some View {
        Group {
            if model.isMutating || (model.isLoading && model.status == nil) {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    // Match the desktop capsule without changing touch chrome.
                    .font(
                        .system(
                            size: usesDesktopChrome ? 18 : 17,
                            weight: usesDesktopChrome ? .regular : .semibold))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var body: some View {
        Button(action: tap) {
            if usesDesktopChrome {
                statusLabel.contentShape(Rectangle())
            } else {
                statusLabel.contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .disabled(model.isMutating || (model.status == nil && !model.loadFailed))
        .accessibilityLabel("Thread subscription")
        .accessibilityValue(Text(stateTitle))
        .accessibilityHint(Text(actionTitle))
        .accessibilityIdentifier("thread-subscription-control")
        .confirmationDialog(
            "Archive thread?", isPresented: $confirmsArchive, titleVisibility: .visible
        ) {
            Button("Archive") { Task { await model.perform(.archive) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This thread will move to Archived. You can unarchive it from here or the list.")
        }
        .alert(
            "Couldn’t update thread",
            isPresented: Binding(
                get: { model.failureMessage != nil },
                set: { if !$0 { model.failureMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.failureMessage = nil }
        } message: {
            Text(model.failureMessage ?? "")
        }
    }

    private func tap() {
        guard let status = model.status else { return model.reload() }
        if !status.subscribed {
            Task { await model.perform(.subscribe) }
        } else if status.archived {
            Task { await model.perform(.unarchive) }
        } else {
            confirmsArchive = true
        }
    }

    /// Subscribed threads use the accent color; the unsubscribed bell stays secondary.
    private var isActive: Bool {
        model.status?.subscribed ?? false
    }

    private var symbol: String {
        guard let status = model.status else {
            return model.loadFailed ? "exclamationmark.arrow.circlepath" : "bell"
        }
        if !status.subscribed { return "bell" }
        return status.archived ? "archivebox.fill" : "archivebox"
    }

    private var stateTitle: LocalizedStringKey {
        guard let status = model.status else {
            return model.loadFailed ? "Subscription unavailable" : "Loading subscription"
        }
        if !status.subscribed { return "Not subscribed" }
        return status.archived ? "Archived" : "Subscribed"
    }

    private var actionTitle: LocalizedStringKey {
        guard let status = model.status else { return "Retry" }
        if !status.subscribed { return "Subscribe" }
        return status.archived ? "Unarchive" : "Archive"
    }
}
