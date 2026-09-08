import ChahuaAPI

/// The loaded, chronologically ordered slice of one conversation.
struct TimelineWindow: Equatable {
    private(set) var messages: [MessageResponse] = []
    private var indexByStableKey: [ConversationMessageStableKey: Int] = [:]
    private var indexByServerID: [String: Int] = [:]
    private(set) var olderCursor: String?
    private(set) var newerCursor: String?

    var isAtLiveEdge: Bool { newerCursor == nil }
    var hasOlder: Bool { olderCursor != nil }
    var count: Int { messages.count }
    /// Identities in this loaded slice, independent of any other window.
    var stableKeys: Set<ConversationMessageStableKey> { Set(indexByStableKey.keys) }

    func index(of stableKey: ConversationMessageStableKey) -> Int? { indexByStableKey[stableKey] }

    func index(ofServerID id: String) -> Int? { indexByServerID[id] }

    func index(matching message: MessageResponse) -> Int? {
        indexByServerID[message.id] ?? (message.clientGeneratedId.isEmpty ? nil : indexByStableKey[message.timelineStableKey])
    }

    mutating func replace(with page: ListMessagesResponse, accepting: (MessageResponse) -> Bool = { _ in true }) {
        messages = []
        rebuildIndexes()
        mergeAuthoritative(page.messages.filter(accepting))
        olderCursor = page.olderCursor
        newerCursor = page.newerCursor
    }

    @discardableResult
    mutating func prependOlder(_ page: ListMessagesResponse, accepting: (MessageResponse) -> Bool = { _ in true }) -> Int {
        let previousCount = count
        mergeAuthoritative(page.messages.filter(accepting))
        olderCursor = page.messages.isEmpty ? nil : page.olderCursor
        return count - previousCount
    }

    @discardableResult
    mutating func appendNewer(_ page: ListMessagesResponse, accepting: (MessageResponse) -> Bool = { _ in true }) -> Int {
        let previousCount = count
        mergeAuthoritative(page.messages.filter(accepting))
        newerCursor = page.messages.isEmpty ? nil : page.newerCursor
        return count - previousCount
    }

    enum LiveInsertOutcome: Equatable {
        case appended
        case duplicate
        case deferred
    }

    mutating func insertLive(_ message: MessageResponse) -> LiveInsertOutcome {
        // A duplicate create is not a mutable snapshot, even in a historical window.
        guard index(matching: message) == nil else { return .duplicate }
        guard isAtLiveEdge else { return .deferred }
        messages.append(message)
        messages = Self.chronological(messages)
        rebuildIndexes()
        return .appended
    }

    @discardableResult
    mutating func upsert(_ message: MessageResponse) -> Bool {
        guard let index = index(matching: message) else { return false }
        replaceRecord(at: index, with: message)
        messages = Self.chronological(messages)
        rebuildIndexes()
        return true
    }

    private mutating func mergeAuthoritative(_ incoming: [MessageResponse]) {
        for message in incoming {
            if let index = index(matching: message) {
                replaceRecord(at: index, with: message)
            } else {
                let index = messages.count
                messages.append(message)
                indexByServerID[message.id] = index
                indexByStableKey[message.timelineStableKey] = index
            }
        }
        messages = Self.chronological(messages)
        rebuildIndexes()
    }

    private mutating func replaceRecord(at index: Int, with message: MessageResponse) {
        let conflictingIndex = indexByStableKey[message.timelineStableKey]
        let previous = messages[index]
        indexByServerID.removeValue(forKey: previous.id)
        indexByStableKey.removeValue(forKey: previous.timelineStableKey)
        messages[index] = message
        if let conflictingIndex, conflictingIndex != index {
            messages.remove(at: conflictingIndex)
            rebuildIndexes()
        } else {
            indexByServerID[message.id] = index
            indexByStableKey[message.timelineStableKey] = index
        }
    }

    @discardableResult
    mutating func remove(serverID: String) -> Bool {
        guard let index = indexByServerID[serverID] else { return false }
        messages.remove(at: index)
        rebuildIndexes()
        return true
    }

    @discardableResult
    mutating func remove(stableKey: ConversationMessageStableKey) -> Bool {
        guard let index = indexByStableKey[stableKey] else { return false }
        messages.remove(at: index)
        rebuildIndexes()
        return true
    }

    enum TrimSide {
        case oldest
        case newest
    }

    @discardableResult
    mutating func trim(_ side: TrimSide, toCount maximum: Int) -> Int {
        precondition(maximum > 0, "A timeline window must retain at least one message.")
        guard count > maximum else { return 0 }

        let removedCount = count - maximum
        switch side {
        case .oldest:
            messages.removeFirst(removedCount)
            olderCursor = messages.first?.id
        case .newest:
            messages.removeLast(removedCount)
            newerCursor = messages.last?.id
        }
        rebuildIndexes()
        return removedCount
    }

    static func chronological(_ page: [MessageResponse]) -> [MessageResponse] {
        page.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.timelineStableKey.sortValue < $1.timelineStableKey.sortValue
        }
    }

    private mutating func rebuildIndexes() {
        indexByStableKey = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.timelineStableKey, $0.offset) })
        indexByServerID = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
    }
}
