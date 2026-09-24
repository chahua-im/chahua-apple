import Foundation

extension MessageMenuAction {
    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .copyLink: "link"
        case .reply: "arrowshape.turn.up.left"
        case .thread: "bubble.left.and.bubble.right"
        case .pin: "pin"
        case .unpin: "pin.slash"
        case .edit: "pencil"
        case .delete: "trash"
        case .save: "bookmark"
        case .favorite: "star"
        case .reactionDetails: "face.smiling"
        }
    }

    func label(hasAttachments: Bool) -> String {
        switch self {
        case .copy:
            hasAttachments ? AppLanguage.localized("Copy Text") : AppLanguage.localized("Copy")
        case .copyLink: AppLanguage.localized("Copy Link")
        case .reply: AppLanguage.localized("Reply")
        case .thread: AppLanguage.localized("Thread")
        case .pin: AppLanguage.localized("Pin")
        case .unpin: AppLanguage.localized("Unpin")
        case .edit: AppLanguage.localized("Edit")
        case .delete: AppLanguage.localized("Delete")
        case .save: AppLanguage.localized("Save")
        case .favorite: AppLanguage.localized("Favorite")
        case .reactionDetails: AppLanguage.localized("Reactions")
        }
    }
}
