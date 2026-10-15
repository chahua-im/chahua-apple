import ChahuaAPI
import SwiftUI

/// Chat-scoped message search, presented as a sheet over the conversation.
///
/// The field is an inline SwiftUI `TextField` rather than `.searchable`, which
/// renders in the toolbar on macOS and is not reliably available inside sheets.
struct MessageSearchView: View {
    @ObservedObject var model: MessageSearchModel
    let onSelect: (MessageResponse) -> Void

    @FocusState private var isFieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Search")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        // A restored search keeps its results visible instead of raising the keyboard.
        .onAppear { isFieldFocused = model.queryText.isEmpty }
    }

    private var controls: some View {
        VStack(spacing: ChahuaTheme.Spacing.medium) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search messages", text: $model.queryText)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($isFieldFocused)
                    .onSubmit { model.submit() }
                    .accessibilityIdentifier("message-search-field")
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                    #endif
                if !model.queryText.isEmpty {
                    Button {
                        model.queryText = ""
                        isFieldFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10))

            Picker("Sort messages", selection: $model.sort) {
                Text("Best").tag(MessageSearchSort.relevance)
                Text("Recent").tag(MessageSearchSort.newest)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("message-search-sort")
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            ChahuaEmptyStateView(
                title: "Search messages in this chat",
                message: "Enter at least 2 characters",
                systemImage: "magnifyingglass")
        case .tooShort:
            ChahuaEmptyStateView(
                title: "Keep typing",
                message: "Enter at least 2 characters",
                systemImage: "character.cursor.ibeam")
        case .loading:
            ProgressView()
        case .failed(let failure):
            ChahuaRecoverableErrorView(
                title: "Couldn’t search messages",
                message: failure == .unavailable
                    ? "Message search is unavailable on this server right now."
                    : "Check your connection and try again.",
                retryTitle: "Try again",
                onRetry: model.retry)
        case .loaded where model.results.isEmpty:
            ChahuaEmptyStateView(
                title: "No messages found",
                message: "Try different words.",
                systemImage: "text.magnifyingglass")
        case .loaded:
            resultList
        }
    }

    private var resultList: some View {
        List {
            ForEach(model.results, id: \.id) { message in
                Button {
                    onSelect(message)
                } label: {
                    MessageSearchResultRow(message: message)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("message-search-result-\(message.id.description)")
                .onAppear {
                    if message.id == model.results.last?.id, !model.loadMoreFailed {
                        model.loadMore()
                    }
                }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .accessibilityLabel("Loading more results")
            } else if model.loadMoreFailed {
                HStack {
                    Text("Couldn’t load more results")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { model.loadMore() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct MessageSearchResultRow: View {
    let message: MessageResponse
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        HStack(alignment: .top, spacing: ChahuaTheme.Spacing.medium) {
            AvatarView(
                url: message.sender.avatarUrl.flatMap(URL.init(string:)),
                displayName: senderName,
                diameter: 40
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(senderName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(timestamp(now: .now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(messagePreview(message.replyPreview))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if message.replyRootId != nil {
                    Label("In thread", systemImage: "bubble.left.and.bubble.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var senderName: String {
        let name = message.sender.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : AppLanguage.localized("User \(message.sender.uid)")
    }

    /// Time today, month and day this year, otherwise the full date.
    private func timestamp(now: Date) -> String {
        let date = message.createdAt
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(
                Date.FormatStyle(locale: locale, calendar: calendar).hour().minute())
        }
        let format = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        return date.formatted(
            calendar.component(.year, from: date) == calendar.component(.year, from: now)
                ? format : format.year())
    }
}
