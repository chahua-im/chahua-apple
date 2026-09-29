import ChahuaAPI
import Foundation
import SwiftUI

struct ReactionDetailsView: View {
    let chatID: String
    let messageID: String
    let load: () async throws -> ReactionDetailResponse

    init(
        chatID: String,
        messageID: String,
        load: @escaping () async throws -> ReactionDetailResponse
    ) {
        self.chatID = chatID
        self.messageID = messageID
        self.load = load
    }

    @Environment(\.dismiss) private var dismiss
    @State private var loadState: ReactionDetailsLoadState = .loading
    @State private var selectedCategoryID: ReactionDetailsCategory.ID = .all
    @State private var selectedInput: ReactionDetailsRequestInput?
    @State private var activeRequest: ReactionDetailsRequestKey?
    @State private var retryAttempt = 0

    private var requestKey: ReactionDetailsRequestKey {
        ReactionDetailsRequestKey(
            input: ReactionDetailsRequestInput(chatID: chatID, messageID: messageID),
            retryAttempt: retryAttempt
        )
    }
    @ScaledMetric(relativeTo: .body) private var tabHeight: CGFloat = 40

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Reactions")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
            .frame(
                minWidth: 400,
                idealWidth: 480,
                maxWidth: 580,
                minHeight: 320,
                idealHeight: 420,
                maxHeight: 600
            )
        #endif
        .task(id: requestKey) {
            await loadReactionDetails(for: requestKey)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            ChahuaLoadingView(title: "Loading reactions…")
                .accessibilityIdentifier("reaction-details-loading")
        case .failed:
            ChahuaRecoverableErrorView(
                title: "Couldn’t load reactions",
                message: "Check your connection and try again.",
                retryTitle: "Retry",
                onRetry: retry
            )
            .accessibilityIdentifier("reaction-details-error")
        case .empty:
            ChahuaEmptyStateView(
                title: "No reactions",
                message: "Reactions will appear here when they are available.",
                systemImage: "face.smiling"
            )
            .accessibilityIdentifier("reaction-details-empty")
        case .loaded(let grouping):
            categoryContent(grouping)
                .accessibilityIdentifier("reaction-details-content")
        }
    }

    @ViewBuilder
    private func categoryContent(_ grouping: ReactionDetailsGrouping) -> some View {
        let activeCategory =
            grouping.categories.first { $0.id == selectedCategoryID }
            ?? grouping.categories.first

        VStack(spacing: 0) {
            categoryTabs(grouping.categories, activeCategoryID: activeCategory?.id)
            if let activeCategory {
                users(for: activeCategory)
            }
        }
    }

    private func categoryTabs(
        _ categories: [ReactionDetailsCategory],
        activeCategoryID: ReactionDetailsCategory.ID?
    ) -> some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(categories) { category in
                        categoryButton(category, isSelected: category.id == activeCategoryID)
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: tabHeight + 3)
        .background(alignment: .bottom) {
            Divider()
        }
    }

    private func categoryButton(
        _ category: ReactionDetailsCategory, isSelected: Bool
    ) -> some View {
        Button {
            selectedCategoryID = category.id
        } label: {
            // Match the conversation scope picker: count badge and an accent underline.
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    categoryLabel(category)
                        .font(.body.weight(.medium))
                    Text(category.count, format: .number)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minHeight: 18)
                        .background(Color.accentColor, in: Capsule())
                }
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 12)
                .frame(height: tabHeight)
                Capsule()
                    .fill(isSelected ? Color.accentColor : .clear)
                    .frame(height: 3)
            }
            .frame(minWidth: 64, maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(categoryAccessibilityLabel(category))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func categoryLabel(_ category: ReactionDetailsCategory) -> some View {
        switch category.id {
        case .all:
            Text("All")
        case .emoji(let emoji):
            Text(emoji)
        case .more:
            Text("More")
        }
    }

    private func users(for category: ReactionDetailsCategory) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(category.users.indices, id: \.self) { index in
                    ReactionDetailsReactorRow(
                        user: category.users[index], showsEmojis: category.showsEmojis)
                    if index + 1 < category.users.count {
                        Divider().padding(.leading, 44)
                    }
                }
            }
            .padding(.horizontal, ChahuaTheme.Spacing.large)
            .padding(.vertical, ChahuaTheme.Spacing.small)
        }
        .id(category.id)
    }

    private func loadReactionDetails(for key: ReactionDetailsRequestKey) async {
        activeRequest = key
        if selectedInput != key.input {
            selectedInput = key.input
            selectedCategoryID = .all
        }
        loadState = .loading

        do {
            let response = try await load()
            guard !Task.isCancelled, activeRequest == key else { return }

            let grouping = ReactionDetailsGrouping(groups: response.reactions)
            loadState = grouping.categories.isEmpty ? .empty : .loaded(grouping)
        } catch is CancellationError {
            // SwiftUI cancels this task when its input changes or the sheet disappears.
        } catch {
            guard !Task.isCancelled, activeRequest == key else { return }
            loadState = .failed
        }
    }

    private func retry() {
        retryAttempt += 1
    }

    private func categoryAccessibilityLabel(_ category: ReactionDetailsCategory) -> Text {
        switch category.id {
        case .all:
            Text("All, \(category.count) people")
        case .emoji(let emoji):
            Text("\(emoji), \(category.count) reactions")
        case .more:
            Text("More, \(category.count) reactions")
        }
    }
}

private enum ReactionDetailsLoadState {
    case loading
    case failed
    case empty
    case loaded(ReactionDetailsGrouping)
}

private struct ReactionDetailsRequestInput: Hashable {
    let chatID: String
    let messageID: String
}

private struct ReactionDetailsRequestKey: Hashable {
    let input: ReactionDetailsRequestInput
    let retryAttempt: Int
}

private struct ReactionDetailsReactorRow: View {
    let user: ReactionDetailsGroupedReactor
    let showsEmojis: Bool

    private var displayName: String {
        let name = user.reactor.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : AppLanguage.localized("User \(user.reactor.uid)")
    }

    var body: some View {
        HStack(spacing: ChahuaTheme.Spacing.medium) {
            AvatarView(
                url: user.reactor.avatarUrl.flatMap(URL.init(string:)),
                displayName: displayName,
                diameter: 32
            )
            .accessibilityHidden(true)

            Text(displayName)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if showsEmojis, !user.emojis.isEmpty {
                Text(user.emojis.joined(separator: " "))
                    .font(.body)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: Text {
        guard showsEmojis, !user.emojis.isEmpty else { return Text(displayName) }
        return Text("\(displayName), \(user.emojis.joined(separator: " "))")
    }
}
