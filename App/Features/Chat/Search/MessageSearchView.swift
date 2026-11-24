import ChahuaAPI
import SwiftUI

/// Chat-scoped search shared by navigation destinations and the desktop side panel.
/// An inline field keeps panel search beside its results instead of in the window toolbar.
struct MessageSearchView: View {
    @ObservedObject var model: MessageSearchModel
    let onSelect: (MessageResponse) -> Void
    var onClose: (() -> Void)? = nil
    var isPanel: Bool = false

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isPanel {
                HStack {
                    Button {
                        onClose?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .frame(width: 24, height: 24)
                            .background(.quaternary, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close search")
                    Text("Search").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            controls
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Search")
        // Desktop panels focus restored queries too; iOS avoids raising the keyboard.
        .onAppear { isFieldFocused = isPanel || model.queryText.isEmpty }
        #if os(macOS)
            .onExitCommand {
                if isPanel { onClose?() }
            }
        #endif
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: ChahuaTheme.Spacing.small) {
                searchField
                if !isPanel { sortMenu }
            }
            if isPanel {
                Picker("Sort messages", selection: $model.sort) {
                    Text("Relevance").tag(MessageSearchSort.relevance)
                    Text("Newest").tag(MessageSearchSort.newest)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("message-search-sort")
            }
        }
        .padding(16)
    }

    private var searchField: some View {
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
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isFieldFocused ? Color.accentColor : .clear, lineWidth: 2)
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort messages", selection: $model.sort) {
                Text("Best").tag(MessageSearchSort.relevance)
                Text("Recent").tag(MessageSearchSort.newest)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(model.sort == .relevance ? LocalizedStringKey("Best") : "Recent")
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10))
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Sort messages")
        .accessibilityValue(
            Text(model.sort == .relevance ? LocalizedStringKey("Best") : "Recent")
        )
        .accessibilityIdentifier("message-search-sort")
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            if isPanel {
                Text("Enter at least 2 characters")
                    .foregroundStyle(.secondary)
            } else {
                ChahuaEmptyStateView(
                    title: "Search messages in this chat",
                    message: "Enter at least 2 characters",
                    systemImage: "magnifyingglass")
            }
        case .tooShort:
            if isPanel {
                Text("Enter at least 2 characters")
                    .foregroundStyle(.secondary)
            } else {
                ChahuaEmptyStateView(
                    title: "Keep typing",
                    message: "Enter at least 2 characters",
                    systemImage: "character.cursor.ibeam")
            }
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
            if isPanel {
                Text("No messages found").foregroundStyle(.secondary)
            } else {
                ChahuaEmptyStateView(
                    title: "No messages found",
                    message: "Try different words.",
                    systemImage: "text.magnifyingglass")
            }
        case .loaded:
            resultList
        }
    }

    private var resultList: some View {
        List {
            ForEach(model.results, id: \.id) { message in
                Button {
                    model.selectedMessageID = message.id
                    onSelect(message)
                } label: {
                    MessageSearchResultRow(message: message, query: model.resultsQuery)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("message-search-result-\(message.id.description)")
                .listRowBackground(
                    model.selectedMessageID == message.id ? Color.accentColor.opacity(0.12) : .clear
                )
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
    let query: String
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
                snippet
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    @ViewBuilder
    private var snippet: some View {
        let preview = message.replyPreview
        let nodes = MessageSummaryContent.summary(preview)
        if message.message?.isEmpty == false, !message.isDeleted,
            !MessageSummaryContent.containsSpoilers(nodes)
        {
            Text(highlighted(MessageSummaryContent.plain(nodes, mentions: preview.mentions)))
                .font(.system(size: 15))
                .lineLimit(2)
        } else {
            // Keep attachment, sticker, system, and spoiler previews in the shared renderer.
            MessageSummaryText(preview, lineLimit: 2)
        }
    }

    private func highlighted(_ summary: String) -> AttributedString {
        guard !query.isEmpty else { return AttributedString(summary) }
        // Keep the first match within the two-line excerpt, including long messages.
        let firstMatch = summary.range(
            of: query, options: [.caseInsensitive, .diacriticInsensitive])
        let excerptStart =
            firstMatch.map {
                summary.index($0.lowerBound, offsetBy: -32, limitedBy: summary.startIndex)
                    ?? summary.startIndex
            } ?? summary.startIndex
        let text =
            (excerptStart == summary.startIndex ? "" : "…")
            + summary[excerptStart...]
        var result = AttributedString(text)
        var start = text.startIndex
        while start < text.endIndex,
            let range = text.range(
                of: query, options: [.caseInsensitive, .diacriticInsensitive],
                range: start..<text.endIndex),
            let attributedRange = Range(range, in: result)
        {
            result[attributedRange].backgroundColor = Color.primary.opacity(0.2)
            start = range.upperBound
        }
        return result
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
