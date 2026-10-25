import ChahuaAPI
import Foundation

extension SpeakingMode {
    nonisolated var localizedTitle: String {
        switch self {
        case .unrestricted: AppLanguage.localized("Unrestricted")
        case .threadsOnly: AppLanguage.localized("Threads Only")
        case .repliesOnly: AppLanguage.localized("Replies Only")
        case .readOnly: AppLanguage.localized("Read Only")
        }
    }

    nonisolated var restrictionExplanation: String {
        switch self {
        case .unrestricted: AppLanguage.localized("You can send messages and replies.")
        case .threadsOnly: AppLanguage.localized("You can only send messages in threads.")
        case .repliesOnly: AppLanguage.localized("You can only reply in existing threads.")
        case .readOnly: AppLanguage.localized("You cannot send or edit messages in this group.")
        }
    }
}

extension MembershipMessageVisibility {
    nonisolated var localizedTitle: String {
        switch self {
        case .members: AppLanguage.localized("All Members")
        case .admins: AppLanguage.localized("Admins Only")
        case .nobody: AppLanguage.localized("Nobody")
        }
    }
}
