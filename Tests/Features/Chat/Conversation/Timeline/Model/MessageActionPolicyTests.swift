import ChahuaAPI
import Foundation
import XCTest

@testable import chahua_apple

@MainActor
final class MessageActionPolicyTests: XCTestCase {
    private let writable = MessageInteractionContext(canWrite: true)

    func testCopyIsEnabledWhileRelevantUnimplementedActionsStayDisabled() {
        let policy = MessageActionPolicy(messageType: .text, text: "Hello", context: writable)
        XCTAssertEqual(policy.availability(of: .copy), .enabled)
        XCTAssertEqual(policy.availability(of: .reply), .unimplemented)
        XCTAssertEqual(policy.availability(of: .thread), .unimplemented)
        XCTAssertEqual(policy.availability(of: .delete), .hidden)
        XCTAssertEqual(policy.availability(of: .edit), .hidden)
        XCTAssertEqual(policy.actions.filter { policy.availability(of: $0) == .enabled }, [.copy])
    }

    func testWhitespaceAndNonTextMediaCannotBeCopied() {
        XCTAssertEqual(MessageActionPolicy(messageType: .text, text: " \n\t ").availability(of: .copy), .hidden)
        XCTAssertEqual(MessageActionPolicy(messageType: .audio, text: "transcript").availability(of: .copy), .hidden)
        XCTAssertEqual(MessageActionPolicy(messageType: .file, text: "caption").availability(of: .copy), .enabled)
    }

    func testOwnershipAndAdminHaveDifferentEditAndDeletePermissions() {
        let owner = MessageActionPolicy(messageType: .text, isOwn: true, context: writable)
        XCTAssertEqual(owner.availability(of: .edit), .unimplemented)
        XCTAssertEqual(owner.availability(of: .delete), .unimplemented)
        XCTAssertEqual(owner.availability(of: .pin), .hidden)

        let admin = MessageActionPolicy(
            messageType: .text,
            context: .init(canWrite: true, isAdmin: true, isPinned: true))
        XCTAssertEqual(admin.availability(of: .edit), .hidden)
        XCTAssertEqual(admin.availability(of: .delete), .unimplemented)
        XCTAssertEqual(admin.availability(of: .pin), .hidden)
        XCTAssertEqual(admin.availability(of: .unpin), .unimplemented)
        XCTAssertEqual(
            MessageActionPolicy(messageType: .file, isOwn: true, context: writable)
                .availability(of: .edit), .hidden)
    }

    func testExistingThreadsAndThreadViewsCannotCreateNestedThreads() {
        XCTAssertEqual(
            MessageActionPolicy(messageType: .text, hasThreadInfo: true, context: writable)
                .availability(of: .thread), .hidden)
        XCTAssertEqual(
            MessageActionPolicy(messageType: .text, context: .init(canWrite: true, isThreadView: true))
                .availability(of: .thread), .hidden)
        XCTAssertEqual(
            MessageActionPolicy(messageType: .audio, context: writable)
                .availability(of: .thread), .hidden)
    }

    func testStickerAndInviteUseTheirRestrictedActionSets() {
        let context = MessageInteractionContext(canWrite: true, isAdmin: true)
        let sticker = MessageActionPolicy(
            messageType: .sticker, text: "Sticker", isOwn: true,
            hasReactions: true, context: context)
        XCTAssertEqual(sticker.actions, [.reply, .favorite, .copyLink, .delete])
        XCTAssertFalse(sticker.canReact)
        let invite = MessageActionPolicy(
            messageType: .invite, text: "Invite", isOwn: true,
            hasReactions: true, context: context)
        XCTAssertEqual(invite.actions, [.reply, .pin, .delete])
        XCTAssertFalse(invite.canReact)
    }

    func testDeadDMRetainsReadOnlyHistoryActionsWithoutWritesOrLinks() {
        let policy = MessageActionPolicy(
            messageType: .text, text: "History", isOwn: true,
            hasReactions: true, context: .init(isDM: true, isAdmin: true))
        XCTAssertEqual(policy.actions, [.copy, .save, .reactionDetails])
        XCTAssertFalse(policy.canReact)
        XCTAssertEqual(policy.availability(of: .copy), .enabled)
        XCTAssertEqual(policy.availability(of: .delete), .hidden)
        XCTAssertEqual(policy.availability(of: .copyLink), .hidden)
    }

    func testPendingSystemAndDeletedMessagesCannotMutate() {
        let pending = MessageActionPolicy(
            messageType: .text, text: "Sending", isPending: true,
            isOwn: true, context: writable)
        XCTAssertEqual(pending.actions, [.copy])
        XCTAssertFalse(pending.canReact)
        let system = MessageActionPolicy(messageType: .system, text: "Joined", isOwn: true, context: writable)
        XCTAssertEqual(system.actions, [.copy])
        XCTAssertFalse(system.canReact)
        let deleted = MessageActionPolicy(
            messageType: .text, text: "Stale sensitive text", isDeleted: true,
            isOwn: true, hasReactions: true, context: writable)
        XCTAssertEqual(deleted.actions, [.reply, .copyLink, .reactionDetails])
        XCTAssertTrue(deleted.actions.allSatisfy { deleted.availability(of: $0) == .unimplemented })
        XCTAssertEqual(deleted.availability(of: .copy), .hidden)
        XCTAssertFalse(deleted.canReact)
    }

    func testDeletedMessagesRetainTypeAndDMRestrictions() {
        let deletedSticker = MessageActionPolicy(
            messageType: .sticker, isDeleted: true,
            hasReactions: true, context: writable)
        XCTAssertEqual(deletedSticker.actions, [.reply, .copyLink])
        let deletedInvite = MessageActionPolicy(
            messageType: .invite, isDeleted: true,
            hasReactions: true, context: .init(canWrite: true, isAdmin: true))
        XCTAssertEqual(deletedInvite.actions, [.reply])
        let deletedDeadDM = MessageActionPolicy(
            messageType: .text, isDeleted: true,
            hasReactions: true, context: .init(isDM: true))
        XCTAssertEqual(deletedDeadDM.actions, [.reactionDetails])
    }

    func testPersonalLimitAllowsRemovalButNotAnotherUsersReaction() throws {
        let mine = try (0..<5).map { try reaction("mine-\($0)", mine: true) }
        let policy = MessageReactionEligibility(
            canReact: true, isReacting: false,
            reactions: mine + [try reaction("other", mine: false)])
        XCTAssertTrue(policy.personalLimitReached)
        XCTAssertTrue(policy.canToggle("mine-0"))
        XCTAssertFalse(policy.canToggle("other"))
        XCTAssertFalse(policy.canToggle("new"))
        XCTAssertTrue(policy.isSelected("mine-0"))
    }

    func testDistinctLimitAllowsExistingReactionAndAuthoritativeUnknownOwnership() throws {
        let reactions = try (0..<50).map { try reaction("emoji-\($0)", mine: $0 == 0 ? nil : false) }
        let policy = MessageReactionEligibility(canReact: true, isReacting: false, reactions: reactions)
        XCTAssertTrue(policy.distinctLimitReached)
        XCTAssertTrue(policy.canToggle("emoji-0"))
        XCTAssertFalse(policy.isSelected("emoji-0"))
        XCTAssertTrue(policy.canToggle("emoji-1"))
        XCTAssertFalse(policy.canToggle("new"))
    }

    func testUnknownOwnershipRemainsResolvableAtPersonalLimit() throws {
        let reactions =
            try (0..<5).map { try reaction("mine-\($0)", mine: true) }
            + [reaction("unknown", mine: nil)]
        let policy = MessageReactionEligibility(canReact: true, isReacting: false, reactions: reactions)
        XCTAssertTrue(policy.canToggle("unknown"))
        XCTAssertFalse(policy.isSelected("unknown"))
    }

    func testPendingRequestAndReadOnlyConversationDisableEvenRemovals() throws {
        let selected = [try reaction("👍", mine: true)]
        XCTAssertFalse(MessageReactionEligibility(canReact: true, isReacting: true, reactions: selected).canToggle("👍"))
        XCTAssertFalse(
            MessageReactionEligibility(canReact: false, isReacting: false, reactions: selected).canToggle("👍"))
    }

    func testRecordingRecentChoicesPreservesPinnedOrderAndDeduplicates() {
        let stored = MessageReactionPreferences.recording("😮", in: "❤️|😮|😂|😮")
        XCTAssertEqual(MessageReactionPreferences.recent(from: stored), ["😮", "❤️", "😂"])
        XCTAssertEqual(MessageReactionPreferences.quick(from: stored), ["👍", "😮", "❤️", "😂"])
        XCTAssertEqual(MessageReactionPreferences.recording("👍", in: stored), stored)
    }

    private func reaction(_ emoji: String, mine: Bool?) throws -> ReactionSummary {
        var value: [String: Any] = ["emoji": emoji, "count": 1]
        if let mine { value["reactedByMe"] = mine }
        return try JSONDecoder().decode(ReactionSummary.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
