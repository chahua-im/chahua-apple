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
    /// Stable keys of every loaded message; used to reconcile buffered live arrivals after a reload.
    var stableKeys: Set<ConversationMessageStableKey> { Set(indexByStableKey.keys) }

    func index(of stableKey: ConversationMessageStableKey) -> Int? { indexByStableKey[stableKey] }

    func index(ofServerID id: String) -> Int? { indexByServerID[id] }

    mutating func replace(with page: ListMessagesResponse) {
        messages = Self.chronological(page.messages)
        olderCursor = page.olderCursor
        newerCursor = page.newerCursor
        rebuildIndexes()
    }

    @discardableResult
    mutating func prependOlder(_ page: ListMessagesResponse) -> Int {
        let fresh = Self.chronological(page.messages).filter { indexByStableKey[$0.timelineStableKey] == nil }
        messages = fresh + messages
        olderCursor = page.messages.isEmpty ? nil : page.olderCursor
        rebuildIndexes()
        return fresh.count
    }

    @discardableResult
    mutating func appendNewer(_ page: ListMessagesResponse) -> Int {
        let fresh = Self.chronological(page.messages).filter { indexByStableKey[$0.timelineStableKey] == nil }
        messages += fresh
        newerCursor = page.messages.isEmpty ? nil : page.newerCursor
        rebuildIndexes()
        return fresh.count
    }

    enum LiveInsertOutcome: Equatable {
        case appended
        case updated
        case deferred
    }

    mutating func insertLive(_ message: MessageResponse) -> LiveInsertOutcome {
        guard isAtLiveEdge else { return .deferred }

        if let index = indexByStableKey[message.timelineStableKey] {
            messages[index] = message
            rebuildIndexes()
            return .updated
        }

        messages.append(message)
        rebuildIndexes()
        return .appended
    }

    @discardableResult
    mutating func upsert(_ message: MessageResponse) -> Bool {
        guard let index = indexByStableKey[message.timelineStableKey] else { return false }
        messages[index] = message
        rebuildIndexes()
        return true
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
        guard page.count >= 2, let first = page.first, let last = page.last, first.createdAt > last.createdAt else {
            return page
        }
        return page.reversed()
    }

    private mutating func rebuildIndexes() {
        indexByStableKey = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.timelineStableKey, $0.offset) })
        indexByServerID = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
    }
}
