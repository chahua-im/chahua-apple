import ChahuaAPI
import SwiftUI

/// Subscription control in the thread title bar, rendered inside the header's
/// circular glass slot.
///
/// Unsubscribed threads show a bell that subscribes in one tap. Subscribed
/// threads show an archive box: outlined archives after confirmation, filled
/// (archived) unarchives.
struct ThreadSubscriptionMenu: View {
    @ObservedObject var model: ThreadSubscriptionModel
    @State private var confirmsArchive = false

    var body: some View {
        Button(action: tap) {
            Group {
                if model.isMutating || (model.isLoading && model.status == nil) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Circle())
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
