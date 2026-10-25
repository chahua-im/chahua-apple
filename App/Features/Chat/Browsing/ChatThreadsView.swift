import ChahuaAPI
import SwiftUI

/// Each mounted browser retains its exclusive root cursor and newest-first server order.
struct ChatThreadsView: View {
    @ObservedObject var store: ChatStore
    let chatID: String
    let onOpenThread: (MessageResponse) -> Void
    var embedded = false
    var isActive = true
    @Environment(\.colorScheme) private var colorScheme
    @State private var roots: [MessageResponse] = []
    @State private var cursor: MessageID?
    @State private var loaded = false
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        Group {
            if embedded {
                LazyVStack(alignment: .leading, spacing: 12) { rows }
            } else {
                List { rows }
                    .navigationTitle("Threads")
            }
        }
        .task { if isActive && !loaded { await load() } }
        .onChange(of: isActive) { _, active in
            // A section change must not cancel and restart an in-flight page.
            if active && !loaded { Task { await load() } }
        }
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(roots, id: \.id) { root in
            Button {
                onOpenThread(root)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(root.sender.name ?? "User \(root.sender.uid)")
                        .font(.subheadline.weight(.semibold))
                    MessageSummaryText(root.replyPreview, color: .secondary, lineLimit: 2)
                    HStack {
                        Text(root.createdAt, style: .date)
                        Spacer()
                        Label(
                            "\(root.threadInfo?.replyCount ?? 0)",
                            systemImage: "bubble.left.and.bubble.right")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(embedded ? 16 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if embedded {
                        RoundedRectangle(cornerRadius: 18)
                            .fill(ChahuaTheme.ChatBubble.incomingBackground(for: colorScheme))
                    }
                }
            }
            .buttonStyle(.plain)
        }
        if loading {
            ProgressView("Loading threads…")
        } else if failed {
            Button("Couldn’t load threads. Retry") { Task { await load() } }
        } else if loaded && roots.isEmpty {
            Text("No threads in this chat")
                .foregroundStyle(.secondary)
        }
        if loaded && cursor != nil && !loading && !failed {
            Button("Load More") { Task { await load() } }
        } else if loaded && cursor == nil && !roots.isEmpty {
            Text("All threads loaded").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard isActive, !loading, !loaded || cursor != nil else { return }
        loading = true
        failed = false
        defer { loading = false }
        do {
            let page = try await store.browseChatThreads(chatID: chatID, cursor: cursor)
            try Task.checkCancellation()
            var known = Set(roots.lazy.map(\.id))
            for root in page.threads where known.insert(root.id).inserted {
                roots.append(root)
            }
            cursor = page.nextCursor
            loaded = true
        } catch is CancellationError {
        } catch { failed = true }
    }
}
