import ChahuaAPI
import Combine
import SwiftUI

typealias ComposerMemberSearch =
    @MainActor @Sendable (ListMembersQuery) async throws -> [MemberResponse]

/// Both editors use the same chat-scoped picker. Native input owns the caret,
/// mention identities, and IME; this surface only searches and selects members.
struct ComposerMentionSuggestions: View {
    @ObservedObject var input: ComposerInputState
    let wireText: String
    let isEnabled: Bool
    nonisolated let search: ComposerMemberSearch?
    @StateObject private var suggestions = ComposerMentionSuggestionsModel()

    private var mentionedIDs: [Int32] {
        let source = wireText as NSString
        return Array(
            Set(
                MessageMentions.pattern.matches(
                    in: wireText, range: NSRange(location: 0, length: source.length)
                ).compactMap { Int32(source.substring(with: $0.range(at: 1))) })
        ).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            if suggestions.query != nil {
                VStack(spacing: 0) {
                    if suggestions.isLoading {
                        ProgressView("Searching members…")
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else if suggestions.failed {
                        HStack {
                            Text("Couldn’t load members.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Retry") { refresh(force: true) }
                                .modifier(ComposerSendFocus())
                        }
                        .padding(12)
                    } else if suggestions.members.isEmpty {
                        Text("No matching members")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        ScrollViewReader { scroll in
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(suggestions.members) { member in
                                        memberRow(member)
                                            .id(member.uid)
                                    }
                                }
                            }
                            .frame(height: min(CGFloat(suggestions.members.count) * 48, 192))
                            .onChange(of: suggestions.selectedIndex) { _, _ in
                                if let member = suggestions.selectedMember {
                                    scroll.scrollTo(member.uid)
                                }
                            }
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .accessibilityLabel("Mention suggestions")
            }
        }
        .onAppear {
            input.onMentionKey = { [weak suggestions = suggestions, weak input = input] key in
                guard let input else { return false }
                return suggestions?.handle(key, input: input) ?? false
            }
            refresh()
        }
        .onChange(of: input.mentionQuery) { _, _ in refresh() }
        .onChange(of: isEnabled) { _, _ in refresh() }
        .onDisappear {
            input.onMentionKey = nil
            suggestions.dismiss()
        }
        .task(id: mentionedIDs) {
            guard let search else { return }
            await suggestions.resolveNames(mentionedIDs, input: input, search: search)
        }
    }

    private func refresh(force: Bool = false) {
        suggestions.update(
            input.mentionQuery,
            search: search, input: input, enabled: isEnabled, force: force
        )
    }

    private func memberRow(_ member: MemberResponse) -> some View {
        let name = ComposerMentionSuggestionsModel.label(member)
        let selected = suggestions.selectedMember?.uid == member.uid
        return Button {
            suggestions.select(member, input: input)
        } label: {
            HStack(spacing: 10) {
                AvatarView(
                    url: member.avatarUrl.flatMap(URL.init(string:)), displayName: name,
                    diameter: 28
                )
                .accessibilityHidden(true)
                Text(name).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.14) : .clear)
        }
        .buttonStyle(.plain)
        .modifier(ComposerSendFocus())
        .accessibilityLabel("Mention \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
final class ComposerMentionSuggestionsModel: ObservableObject {
    @Published private(set) var query: ComposerMentionQuery?
    @Published private(set) var members: [MemberResponse] = []
    @Published private(set) var selectedIndex = 0
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    private var request: Task<Void, Never>?
    private var dismissedQuery: ComposerMentionQuery?
    private var knownNames: [Int32: String] = [:]
    private var resolvedIDs = Set<Int32>()

    var selectedMember: MemberResponse? {
        members.indices.contains(selectedIndex) ? members[selectedIndex] : nil
    }

    static func label(_ member: MemberResponse) -> String {
        member.username.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(member.uid)"
    }

    func update(
        _ next: ComposerMentionQuery?, search: ComposerMemberSearch?, input: ComposerInputState,
        enabled: Bool = true, force: Bool = false
    ) {
        guard enabled else {
            clear()
            return
        }
        if next != dismissedQuery { dismissedQuery = nil }
        guard let next, let search, next != dismissedQuery else {
            clear()
            return
        }
        guard force || query != next else { return }
        clear()
        query = next
        isLoading = true
        request = Task { [weak self, weak input] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let members = try await search(.init(q: next.query.isEmpty ? nil : next.query))
                guard !Task.isCancelled, let self, let input, self.query == next else { return }
                self.members = members
                self.isLoading = false
                self.remember(members, input: input)
            } catch {
                guard !Task.isCancelled, let self, self.query == next else { return }
                self.isLoading = false
                self.failed = true
            }
        }
    }

    func handle(_ key: ComposerMentionKey, input: ComposerInputState) -> Bool {
        guard query != nil, !input.isComposing else { return false }
        switch key {
        case .dismiss:
            dismiss()
            return true
        case .up:
            guard !members.isEmpty else { return false }
            selectedIndex = max(0, selectedIndex - 1)
            return true
        case .down:
            guard !members.isEmpty else { return false }
            selectedIndex = min(members.count - 1, selectedIndex + 1)
            return true
        case .accept:
            guard let selectedMember else { return false }
            select(selectedMember, input: input)
            return true
        }
    }

    func select(_ member: MemberResponse, input: ComposerInputState) {
        guard let query, !input.isComposing else { return }
        if input.insertMention(uid: member.uid, label: Self.label(member), query: query) {
            dismiss()
        }
    }

    func dismiss() {
        dismissedQuery = query
        clear()
    }

    private func clear() {
        request?.cancel()
        request = nil
        query = nil
        members = []
        selectedIndex = 0
        isLoading = false
        failed = false
    }

    private func remember(_ members: [MemberResponse], input: ComposerInputState) {
        for member in members {
            knownNames[member.uid] = Self.label(member)
            resolvedIDs.insert(member.uid)
        }
        input.setMentionNames(knownNames)
    }

    /// Drafts already persist stable UID tokens. Resolve only their display
    /// labels; an unavailable/departed member keeps the native @User N fallback.
    func resolveNames(_ ids: [Int32], input: ComposerInputState, search: ComposerMemberSearch) async
    {
        for uid in ids where !resolvedIDs.contains(uid) {
            do {
                // Submitted search includes exact UID, ordered by UID. Starting
                // immediately before it avoids collisions with numeric names.
                let members = try await search(
                    .init(
                        q: String(uid), mode: "submitted", limit: 1,
                        after: uid == .min ? nil : uid - 1
                    ))
                guard !Task.isCancelled else { return }
                resolvedIDs.insert(uid)
                remember(members.filter { $0.uid == uid }, input: input)
            } catch {
                if Task.isCancelled { return }
                // Resolution is presentation-only: never replace or lose the UID.
            }
        }
    }
}
