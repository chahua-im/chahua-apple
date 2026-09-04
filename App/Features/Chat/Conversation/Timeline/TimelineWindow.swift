import ChahuaAPI

/// The loaded, chronologically ordered slice of one conversation.
struct TimelineWindow: Equatable {
    private(set) var messages: [MessageResponse] = []
    private(set) var indexByID: [String: Int] = [:]
    private(set) var olderCursor: String?
    private(set) var newerCursor: String?

    var isAtLiveEdge: Bool { newerCursor == nil }
    var hasOlder: Bool { olderCursor != nil }
    var count: Int { messages.count }

    func index(of id: String) -> Int? { indexByID[id] }

    mutating func replace(with page: ListMessagesResponse) {
        messages = Self.chronological(page.messages)
        olderCursor = page.olderCursor
        newerCursor = page.newerCursor
        rebuildIndex()
    }

    @discardableResult
    mutating func prependOlder(_ page: ListMessagesResponse) -> Int {
        let fresh = Self.chronological(page.messages).filter { indexByID[$0.id] == nil }
        messages = fresh + messages
        olderCursor = page.messages.isEmpty ? nil : page.olderCursor
        rebuildIndex()
        return fresh.count
    }

    @discardableResult
    mutating func appendNewer(_ page: ListMessagesResponse) -> Int {
        let fresh = Self.chronological(page.messages).filter { indexByID[$0.id] == nil }
        messages += fresh
        newerCursor = page.messages.isEmpty ? nil : page.newerCursor
        rebuildIndex()
        return fresh.count
    }

    enum LiveInsertOutcome: Equatable {
        case appended
        case updated
        case deferred
    }

    mutating func insertLive(_ message: MessageResponse) -> LiveInsertOutcome {
        guard isAtLiveEdge else { return .deferred }

        if let index = indexByID[message.id] {
            messages[index] = message
            return .updated
        }

        messages.append(message)
        indexByID[message.id] = messages.index(before: messages.endIndex)
        return .appended
    }

    @discardableResult
    mutating func upsert(_ message: MessageResponse) -> Bool {
        guard let index = indexByID[message.id] else { return false }
        messages[index] = message
        return true
    }

    @discardableResult
    mutating func remove(id: String) -> Bool {
        guard let index = indexByID[id] else { return false }
        messages.remove(at: index)
        rebuildIndex()
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
        rebuildIndex()
        return removedCount
    }

    static func chronological(_ page: [MessageResponse]) -> [MessageResponse] {
        guard page.count >= 2, let first = page.first, let last = page.last, first.createdAt > last.createdAt else {
            return page
        }
        return page.reversed()
    }

    private mutating func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($0.element.id, $0.offset) })
    }
}
