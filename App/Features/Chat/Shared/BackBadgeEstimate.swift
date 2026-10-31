/// A deliberately approximate badge, separate from authoritative app-icon/read counters.
/// The first server total retains chats we have never loaded. Later totals cannot
/// safely be subtracted from independently delivered read states, so only per-chat
/// replacements and occasional filtered server snapshots correct this estimate.
/// Ordinary total drift is accepted until reconnect or explicit uncertainty;
/// stream timing differences must never cause a recount on every message.
struct BackBadgeEstimate {
    private struct Chat {
        var unread: Int64
        var eligible: Bool
        var lastReadID: UInt64?
        var messageWatermark: UInt64?

        var contribution: Int64 { eligible ? unread : 0 }
    }

    private static let maximum = Int64(UInt32.max)
    private var total: Int64?
    private var chats: [String: Chat] = [:]
    private var filtered: [String: Int64] = [:]
    private var unseenWatermarks: [String: UInt64] = [:]
    /// Internal cursor/eligibility bookkeeping alone does not invalidate shared UI.
    private(set) var presentationRevision = 0

    mutating func seed(total: Int64) {
        guard self.total == nil else { return }
        self.total = Self.clamp(total)
        presentationRevision &+= 1
    }

    func count(excluding chatID: String?) -> Int? {
        if let chatID, let count = filtered[chatID] { return Int(Self.clamp(count)) }
        guard let total else { return nil }
        guard let chatID else { return Int(Self.clamp(total)) }
        guard let chat = chats[chatID] else { return nil }
        return Int(Self.clamp(total - chat.contribution))
    }

    /// Newly discovered rows are already represented in the server baseline;
    /// only replacements of a known contribution change that baseline.
    mutating func replace(
        chatID: String, unread: Int64, eligible: Bool, lastReadID: UInt64?,
        latestMessageID: UInt64?
    ) {
        let previous = chats[chatID]
        var watermark = previous?.messageWatermark
        if let unseen = unseenWatermarks.removeValue(forKey: chatID) {
            watermark = max(watermark ?? unseen, unseen)
        }
        if let latestMessageID { watermark = max(watermark ?? latestMessageID, latestMessageID) }
        if let lastReadID { watermark = max(watermark ?? lastReadID, lastReadID) }
        let chat = Chat(
            unread: Self.clamp(unread), eligible: eligible, lastReadID: lastReadID,
            messageWatermark: watermark)
        chats[chatID] = chat
        if let previous {
            adjust(chat.contribution - previous.contribution, from: chatID)
        } else if let count = filtered[chatID] {
            // A filtered response can precede this chat's first authorized row.
            total = Self.clamp(count + chat.contribution)
            presentationRevision &+= 1
        }
        if previous == nil, total != nil, filtered[chatID] == nil {
            presentationRevision &+= 1
        }
    }

    mutating func replaceReadState(chatID: String, unread: Int64, lastReadID: UInt64?) -> Bool {
        guard let chat = chats[chatID] else { return false }
        replace(
            chatID: chatID, unread: unread, eligible: chat.eligible,
            lastReadID: lastReadID, latestMessageID: chat.messageWatermark)
        return true
    }

    mutating func setEligibility(chatID: String, eligible: Bool) -> Bool {
        guard var chat = chats[chatID] else { return false }
        let previous = chat.contribution
        chat.eligible = eligible
        chats[chatID] = chat
        adjust(chat.contribution - previous, from: chatID)
        return true
    }

    mutating func remove(chatID: String) {
        guard var chat = chats[chatID] else { return }
        let previous = chat.contribution
        chat.unread = 0
        chat.eligible = false
        chats[chatID] = chat
        adjust(-previous, from: chatID)
    }

    /// Returns false only when an unseen chat needs a coalesced reconciliation.
    /// The monotonic watermark also deduplicates redelivery after reconnect and
    /// ignores older messages already represented by an authoritative snapshot.
    mutating func receive(chatID: String, messageID: UInt64, isOwn: Bool) -> Bool {
        guard var chat = chats[chatID] else {
            if let watermark = unseenWatermarks[chatID], messageID <= watermark { return true }
            unseenWatermarks[chatID] = messageID
            return isOwn
        }
        guard chat.messageWatermark.map({ messageID > $0 }) ?? true else { return true }
        chat.messageWatermark = messageID
        let previous = chat.contribution
        if !isOwn, chat.lastReadID.map({ messageID > $0 }) ?? true {
            chat.unread = Self.clamp(chat.unread + 1)
        }
        chats[chatID] = chat
        adjust(chat.contribution - previous, from: chatID)
        return true
    }

    /// No event watermark exists on this payload. It replaces the estimate at
    /// receipt; deliberately do not replay deltas that raced the server snapshot.
    mutating func replaceFiltered(_ counts: [String: Int64]) {
        // A frame can correct several scenes, including an unloaded exclusion.
        // Rebase once, then install all returned counts without correcting one
        // freshly received scene a second time through another scene's total.
        for (chatID, count) in counts {
            guard let chat = chats[chatID] else { continue }
            let replacement = Self.clamp(Self.clamp(count) + chat.contribution)
            if total != replacement { presentationRevision &+= 1 }
            if let total {
                let correction = replacement - total
                for index in filtered.indices where counts[filtered[index].key] == nil {
                    filtered.values[index] = Self.clamp(filtered[index].value + correction)
                }
            }
            total = replacement
            break
        }
        for (chatID, count) in counts {
            let replacement = Self.clamp(count)
            if filtered[chatID] != replacement {
                filtered[chatID] = replacement
                presentationRevision &+= 1
            }
        }
    }

    private mutating func adjust(_ delta: Int64, from chatID: String) {
        guard delta != 0 else { return }
        if total != nil || !filtered.isEmpty { presentationRevision &+= 1 }
        if let total { self.total = Self.clamp(total + delta) }
        for index in filtered.indices where filtered[index].key != chatID {
            filtered.values[index] = Self.clamp(filtered[index].value + delta)
        }
    }

    private static func clamp(_ count: Int64) -> Int64 {
        max(0, min(maximum, count))
    }
}
