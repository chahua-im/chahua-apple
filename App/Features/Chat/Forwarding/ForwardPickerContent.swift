import ChahuaAPI
import SwiftUI

/// The destination picker and confirmation preview share one sheet and never navigate a chat.
struct ForwardPickerContent: View {
    @ObservedObject var store: ChatStore
    @ObservedObject var model: ForwardDestinationPickerModel
    @Binding var query: String
    let onClose: () -> Void
    let onCompleted: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var usesRegularFooter: Bool {
        // macOS has no horizontal size class. Its sheet uses regular dialog actions;
        // iPad uses the same shared footer while compact iPhone sheets use a full-width action.
        #if os(macOS)
            true
        #else
            horizontalSizeClass == .regular
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            status
            if let target = model.selectedTarget {
                preview(target)
                footer(target)
            } else {
                picker
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(ChahuaTheme.conversationBackground(for: colorScheme))
        .tint(ChahuaTheme.accent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            if model.selectedTarget == nil {
                closeButton
            } else {
                Button(action: model.changeDestination) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 36, height: 36)
                        .background(ChahuaTheme.secondaryBackground, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isSubmitting || model.isResolving)
                .accessibilityLabel("Back to destinations")
                .accessibilityIdentifier("forward-preview-back")
            }
            VStack(alignment: .leading, spacing: 3) {
                if model.selectedTarget == nil {
                    Text("Forward to…")
                        .font(.headline)
                    if model.messageCount == 1 {
                        Text("1 message from \(model.sourceTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(model.messageCount) messages from \(model.sourceTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if model.messageCount == 1 {
                    Text("Forward 1 message")
                        .font(.headline)
                } else {
                    Text("Forward \(model.messageCount) messages")
                        .font(.headline)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
            if model.selectedTarget != nil {
                closeButton
            }
        }
        .padding(16)
    }

    private var closeButton: some View {
        Button(role: .cancel, action: onClose) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .frame(width: 36, height: 36)
                .background(ChahuaTheme.secondaryBackground, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSubmitting)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Close forwarding")
        .accessibilityIdentifier("forward-close")
    }

    @ViewBuilder
    private var status: some View {
        if let failure = model.failure {
            Label(failure.localizedDescription, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(ChahuaTheme.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .accessibilityIdentifier("forward-selection-error")
        }
        if model.isResolving {
            ProgressView("Preparing preview…")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var picker: some View {
        VStack(spacing: 12) {
            searchField
                .padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    Button {
                        model.choose(.saved)
                    } label: {
                        HStack(spacing: 12) {
                            savedAvatar
                            Text("Saved Messages")
                                .font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            destinationChevron
                        }
                        .padding(12)
                        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.selectionBlocked)
                    .accessibilityIdentifier("forward-destination-saved")

                    Text("Recent")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 4)
                    recentDestinations
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search chats and threads", text: $query)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("forward-destination-search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var recentDestinations: some View {
        let targets = model.targets(matching: query)
        VStack(spacing: 0) {
            ForEach(targets) { target in
                Button {
                    model.choose(.conversation(target))
                } label: {
                    HStack(spacing: 12) {
                        conversationIdentity(target)
                        destinationChevron
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.selectionBlocked)
                if target.id != targets.last?.id {
                    Divider().padding(.leading, 64)
                }
            }
        }
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))

        if model.isLoading {
            ProgressView("Loading conversations…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if targets.isEmpty && !model.chatsFailed && !model.threadsFailed {
            Text(
                query.isEmpty
                    ? "No recent conversations" : "No matching conversations in loaded results"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
        }
        if model.chatsFailed {
            retryRow("Could not load chats", action: model.retryChats)
        }
        if model.threadsFailed {
            retryRow("Could not load threads", action: model.retryThreads)
        }
        // Search filters loaded pages only; paging remains available even without matches.
        if model.moreAvailable {
            Button("Load More", action: model.loadMore)
                .frame(maxWidth: .infinity, minHeight: 36)
                .disabled(model.isLoading)
        }
    }

    private func preview(_ target: ForwardDestination) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("From \(model.sourceTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    ForEach(model.previewSources.prefix(3), id: \.id) { source in
                        summaryBubble(source)
                    }
                    if model.messageCount > 3 {
                        Group {
                            if model.messageCount == 4 {
                                Text("+1 more message")
                            } else {
                                Text("+\(model.messageCount - 3) more messages")
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(cardBackground, in: Capsule())
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(ChahuaTheme.secondaryBackground, in: RoundedRectangle(cornerRadius: 12))

                Text("To")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                HStack(spacing: 12) {
                    switch target {
                    case .saved:
                        savedAvatar
                        Text("Saved Messages")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .conversation(let conversation):
                        conversationIdentity(conversation)
                    }
                    Button("Change", action: model.changeDestination)
                        .buttonStyle(.plain)
                        .foregroundStyle(ChahuaTheme.accent)
                        .disabled(model.isSubmitting || model.isResolving)
                        .accessibilityLabel("Change destination")
                }
                .padding(12)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func summaryBubble(_ source: MessageResponse) -> some View {
        let outgoing = source.sender.uid == store.currentUserProfile?.uid
        let foreground =
            outgoing
            ? ChahuaTheme.ChatBubble.outgoingForeground
            : ChahuaTheme.ChatBubble.incomingForeground(for: colorScheme)
        return HStack {
            if outgoing { Spacer(minLength: 28) }
            VStack(alignment: .leading, spacing: 4) {
                Text(source.sender.name ?? AppLanguage.localized("User \(source.sender.uid)"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(outgoing ? foreground.opacity(0.85) : ChahuaTheme.accent)
                MessageSummaryText(
                    source.replyPreview, fontSize: 15, color: foreground, lineLimit: 3,
                    fallback: AppLanguage.localized("Message")
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .background(
                outgoing
                    ? ChahuaTheme.ChatBubble.outgoingBackground
                    : ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 12))
            if !outgoing { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity, alignment: outgoing ? .trailing : .leading)
    }

    private func footer(_ target: ForwardDestination) -> some View {
        VStack(spacing: 12) {
            Divider()
            if usesRegularFooter {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        Button("Cancel", role: .cancel, action: onClose)
                            .buttonStyle(.bordered)
                            .disabled(model.isSubmitting)
                        forwardButton(target, fullWidth: false)
                    }
                    VStack(alignment: .trailing, spacing: 12) {
                        forwardButton(target, fullWidth: true)
                        Button("Cancel", role: .cancel, action: onClose)
                            .buttonStyle(.bordered)
                            .disabled(model.isSubmitting)
                    }
                }
                .controlSize(.regular)
                .padding(.horizontal, 16)
            } else {
                forwardButton(target, fullWidth: true)
                    .controlSize(.large)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 16)
    }

    private func forwardButton(_ target: ForwardDestination, fullWidth: Bool) -> some View {
        Button {
            model.send(onCompleted: onCompleted)
        } label: {
            HStack(spacing: 8) {
                if model.isSubmitting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrowshape.turn.up.right")
                }
                Text("Forward to \(target.title)")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, fullWidth ? 4 : 0)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(model.selectionBlocked)
        .accessibilityIdentifier("forward-send")
    }

    private func conversationIdentity(_ target: ConversationListItem) -> some View {
        HStack(spacing: 12) {
            ConversationAvatarView(item: target, store: store)
            VStack(alignment: .leading, spacing: 4) {
                switch target {
                case .chat(let chat):
                    Text(chat.chatDisplayName)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle = ChatPresenceDisplay.subtitle(for: chat, in: store.state) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let preview = chat.lastMessage {
                        MessageSummaryText(preview, fontSize: 13, color: .secondary)
                    } else {
                        Text(chat.kind == .dm ? "Direct message" : "Group")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .thread(let thread):
                    MessageSummaryText(
                        thread.threadRootMessage, fontSize: 15, weight: .semibold,
                        lineLimit: 2, fallback: AppLanguage.localized("Message"))
                    Label(
                        "\(thread.chatName) · \(thread.replyCount) replies",
                        systemImage: "text.bubble"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savedAvatar: some View {
        Image(systemName: "bookmark.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(ChahuaTheme.accent, in: Circle())
            .accessibilityHidden(true)
    }

    private var destinationChevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private var cardBackground: Color {
        ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme)
    }

    private func retryRow(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Button("Retry", action: action)
        }
        .padding(.vertical, 8)
    }
}
