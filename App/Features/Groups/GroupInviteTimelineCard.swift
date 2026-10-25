import ChahuaAPI
import Foundation

extension TimelineBubbleActions {
    /// Invite cards deliberately open a preview; activation never redeems an invitation.
    func canOpenCard(_ message: MessageResponse?) -> Bool {
        guard let message else { return false }
        if message.messageType == .invite {
            return openLink != nil && GroupInviteLink.code(from: message.message ?? "") != nil
        }
        return openForwardedMessages != nil
    }

    func openCard(_ message: MessageResponse) {
        if message.messageType == .invite {
            guard let code = GroupInviteLink.code(from: message.message ?? ""),
                let url = GroupInviteLink.url(code: code)
            else { return }
            openLink?(url)
        } else {
            openForwardedMessages?(message)
        }
    }
}
