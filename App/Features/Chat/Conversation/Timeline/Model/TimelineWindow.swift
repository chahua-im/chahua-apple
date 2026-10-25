import ChahuaAPI

/// The loaded slice of one conversation, in server order: ascending `MessageID`.
///
/// Snowflake IDs are the server's message order, so order is established once at
/// insertion and no mutation re-sorts the window. Server-ID lookups binary-search
/// `messages`; the only side index maps client-generated IDs to server IDs, which
/// does not depend on array positions and is never rebuilt.
struct TimelineWindow: Equatable {
    private(set) var messages: [MessageResponse] = []
    private var serverIDByClientID: [String: MessageID] = [:]
    private(set) var olderCursor: MessageID?
    private(set) var newerCursor: MessageID?

    var isAtLiveEdge: Bool { newerCursor == nil }
    var hasOlder: Bool { olderCursor != nil }
    var count: Int { messages.count }

    func index(of stableKey: ConversationMessageStableKey) -> Int? {
        switch stableKey {
        case .server(let id):
            guard let index = index(ofServerID: id), messages[index].clientGeneratedId.isEmpty
            else { return nil }
            return index
        case .clientGenerated(let clientID):
            return serverIDByClientID[clientID].flatMap(index(ofServerID:))
        }
    }

    func index(ofServerID id: MessageID) -> Int? {
        let index = firstIndex(notBefore: id)
        return index < messages.count && messages[index].id == id ? index : nil
    }

    func index(matching message: MessageResponse) -> Int? {
        index(ofServerID: message.id)
            ?? (message.clientGeneratedId.isEmpty
                ? nil : index(of: .clientGenerated(message.clientGeneratedId)))
    }

    mutating func replace(
        with page: ListMessagesResponse, accepting: (MessageResponse) -> Bool = { _ in true }
    ) {
        messages = []
        serverIDByClientID = [:]
        mergeAuthoritative(page.messages.filter(accepting))
        olderCursor = page.olderCursor
        newerCursor = page.newerCursor
    }

    @discardableResult
    mutating func prependOlder(
        _ page: ListMessagesResponse, accepting: (MessageResponse) -> Bool = { _ in true }
    ) -> Int {
        let previousCount = count
        mergeAuthoritative(page.messages.filter(accepting))
        olderCursor = page.messages.isEmpty ? nil : page.olderCursor
        return count - previousCount
    }

    @discardableResult
    mutating func appendNewer(
        _ page: ListMessagesResponse, accepting: (MessageResponse) -> Bool = { _ in true }
    ) -> Int {
        let previousCount = count
        mergeAuthoritative(page.messages.filter(accepting))
        newerCursor = page.messages.isEmpty ? nil : page.newerCursor
        return count - previousCount
    }

    /// Recalibrates an already loaded range without replacing its pagination boundaries.
    mutating func mergePreservingCursors(
        _ page: ListMessagesResponse, accepting: (MessageResponse) -> Bool
    ) {
        mergeAuthoritative(page.messages.filter(accepting))
    }

    mutating func removeAll(where shouldRemove: (MessageResponse) -> Bool) {
        messages.removeAll { message in
            guard shouldRemove(message) else { return false }
            if !message.clientGeneratedId.isEmpty {
                serverIDByClientID.removeValue(forKey: message.clientGeneratedId)
            }
            return true
        }
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
        insert(message)
        return .appended
    }

    @discardableResult
    mutating func upsert(_ message: MessageResponse) -> Bool {
        guard let index = index(matching: message) else { return false }
        replaceRecord(at: index, with: message)
        return true
    }

    @discardableResult
    mutating func remove(serverID: MessageID) -> Bool {
        guard let index = index(ofServerID: serverID) else { return false }
        unregister(messages.remove(at: index))
        return true
    }

    @discardableResult
    mutating func remove(stableKey: ConversationMessageStableKey) -> Bool {
        guard let index = index(of: stableKey) else { return false }
        unregister(messages.remove(at: index))
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
            for message in messages[..<removedCount] { unregister(message) }
            messages.removeFirst(removedCount)
            olderCursor = messages.first?.id
        case .newest:
            for message in messages[(count - removedCount)...] { unregister(message) }
            messages.removeLast(removedCount)
            newerCursor = messages.last?.id
        }
        return removedCount
    }

    /// Replaces known records in place and merges unknown ones in one ordered pass.
    /// Within a page, a later record for the same identity wins.
    private mutating func mergeAuthoritative(_ incoming: [MessageResponse]) {
        var additionsByID: [MessageID: MessageResponse] = [:]
        var additionIDByClientID: [String: MessageID] = [:]
        for message in incoming {
            if let index = index(matching: message) {
                replaceRecord(at: index, with: message)
                continue
            }
            if !message.clientGeneratedId.isEmpty {
                if let previous = additionIDByClientID[message.clientGeneratedId],
                    previous != message.id
                {
                    additionsByID.removeValue(forKey: previous)
                }
                additionIDByClientID[message.clientGeneratedId] = message.id
            }
            if let previous = additionsByID[message.id], !previous.clientGeneratedId.isEmpty,
                previous.clientGeneratedId != message.clientGeneratedId
            {
                additionIDByClientID.removeValue(forKey: previous.clientGeneratedId)
            }
            additionsByID[message.id] = message
        }
        guard !additionsByID.isEmpty else { return }
        // Only the page-sized additions are sorted; the loaded window is already ordered.
        let additions = additionsByID.values.sorted { $0.id < $1.id }
        for message in additions { register(message) }
        if let last = messages.last, last.id > additions[0].id {
            messages = Self.merged(messages, additions)
        } else {
            messages.append(contentsOf: additions)
        }
    }

    /// Replaces a record found by server or client identity. An acknowledgement can
    /// carry a different server ID for the same client identity; it moves to that
    /// ID's position, which is the only way an existing record can change order.
    private mutating func replaceRecord(at index: Int, with message: MessageResponse) {
        let previous = messages[index]
        unregister(previous)
        guard previous.id == message.id else {
            messages.remove(at: index)
            removeClientIdentityConflict(with: message)
            insert(message)
            return
        }
        messages[index] = message
        removeClientIdentityConflict(with: message)
        register(message)
    }

    /// Server identity wins: another record holding this client identity is dropped.
    private mutating func removeClientIdentityConflict(with message: MessageResponse) {
        guard !message.clientGeneratedId.isEmpty,
            let other = serverIDByClientID[message.clientGeneratedId], other != message.id,
            let index = index(ofServerID: other)
        else { return }
        unregister(messages.remove(at: index))
    }

    private mutating func insert(_ message: MessageResponse) {
        // Live messages almost always carry the newest ID: append without searching.
        if let last = messages.last, last.id > message.id {
            messages.insert(message, at: firstIndex(notBefore: message.id))
        } else {
            messages.append(message)
        }
        register(message)
    }

    private mutating func register(_ message: MessageResponse) {
        guard !message.clientGeneratedId.isEmpty else { return }
        serverIDByClientID[message.clientGeneratedId] = message.id
    }

    private mutating func unregister(_ message: MessageResponse) {
        guard !message.clientGeneratedId.isEmpty,
            serverIDByClientID[message.clientGeneratedId] == message.id
        else { return }
        serverIDByClientID.removeValue(forKey: message.clientGeneratedId)
    }

    /// First position whose ID is not less than `id`.
    private func firstIndex(notBefore id: MessageID) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let middle = (low + high) / 2
            if messages[middle].id < id { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Linear merge of two ID-ordered sequences with disjoint IDs.
    private static func merged(_ lhs: [MessageResponse], _ rhs: [MessageResponse])
        -> [MessageResponse]
    {
        var result: [MessageResponse] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var left = lhs.startIndex
        var right = rhs.startIndex
        while left < lhs.endIndex, right < rhs.endIndex {
            if lhs[left].id < rhs[right].id {
                result.append(lhs[left])
                left += 1
            } else {
                result.append(rhs[right])
                right += 1
            }
        }
        result.append(contentsOf: lhs[left...])
        result.append(contentsOf: rhs[right...])
        return result
    }
}
