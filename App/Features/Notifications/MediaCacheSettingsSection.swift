import SwiftUI

struct MediaCacheSettingsSection: View {
    @StateObject private var model: MediaCacheSettingsModel
    @State private var confirmsClear = false
    @State private var confirmsHistoryClear = false

    init(context: AppMediaContext, historyCache: AccountHistoryCache) {
        _model = StateObject(wrappedValue: MediaCacheSettingsModel(mediaContext: context, historyCache: historyCache))
    }

    var body: some View {
        Group {
            LabeledContent("Message data") {
                if let size = model.messageStorageSize {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .monospacedDigit()
                } else {
                    Text("—")
                }
            }
            .task { await model.refreshMessageSize() }
            Button("Clear Message History", role: .destructive) { confirmsHistoryClear = true }
                .disabled(model.isClearingMessages)
                .confirmationDialog("Remove downloaded messages?", isPresented: $confirmsHistoryClear) {
                    Button("Clear Message History", role: .destructive) { Task { await model.clearMessages() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Downloaded conversations will be removed from this device. Drafts and unsent messages are kept.")
                }
            if model.isClearingMessages {
                ProgressView("Clearing message history…").controlSize(.small)
            }
            if let error = model.messageError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            LabeledContent("Cached images and media") {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(model.diskStorageSize), countStyle: .file)
                    )
                    .monospacedDigit()
                }
            }
            .task { await model.refresh() }
            Text("Downloaded images can be fetched again. Drafts and unsent messages are kept.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Clear media cache", role: .destructive) { confirmsClear = true }
                .disabled(model.isClearing || model.isRefreshing)
                .confirmationDialog("Remove downloaded media?", isPresented: $confirmsClear) {
                    Button("Clear cache", role: .destructive) { Task { await model.clear() } }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Downloaded images will be removed from this device. Unsent messages will not be affected."
                    )
                }
            if model.isClearing {
                ProgressView("Clearing cache…").controlSize(.small)
            }
            if let error = model.errorDescription {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else if model.state == .cleared {
                Label("Cache cleared", systemImage: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.green)
            }
        }
    }
}
