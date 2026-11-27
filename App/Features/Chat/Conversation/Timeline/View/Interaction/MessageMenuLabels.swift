import Foundation

extension MessageMenuAction {
    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .copyLink: "link"
        case .reply: "arrow.uturn.backward"
        case .thread: "bubble.left.and.bubble.right"
        case .pin: "pin"
        case .unpin: "pin.fill"
        case .edit: "square.and.pencil"
        case .delete: "trash"
        case .select: "checkmark.square"
        case .forward: "arrowshape.turn.up.right"
        case .save: "bookmark"
        case .favorite: "heart"
        case .toSticker: "face.smiling"
        case .reactionDetails: "person.2"
        }
    }

    func symbol(isSaved: Bool, isFavorite: Bool) -> String {
        switch self {
        case .save where isSaved: "bookmark.fill"
        case .favorite where isFavorite: "heart.fill"
        default: symbol
        }
    }

    func label(isSaved: Bool = false, isFavorite: Bool = false) -> String {
        switch self {
        case .copy: AppLanguage.localized("Copy")
        case .copyLink: AppLanguage.localized("Link")
        case .reply: AppLanguage.localized("Reply")
        case .thread: AppLanguage.localized("Thread")
        case .pin: AppLanguage.localized("Pin")
        case .unpin: AppLanguage.localized("Unpin")
        case .edit: AppLanguage.localized("Edit")
        case .delete: AppLanguage.localized("Recall")
        case .select: AppLanguage.localized("Select")
        case .forward: AppLanguage.localized("Forward")
        case .save: isSaved ? AppLanguage.localized("Unsave") : AppLanguage.localized("Save")
        case .favorite: isFavorite ? AppLanguage.localized("Unfav") : AppLanguage.localized("Fav")
        case .toSticker: AppLanguage.localized("To sticker")
        case .reactionDetails: AppLanguage.localized("Reactions")
        }
    }
}
