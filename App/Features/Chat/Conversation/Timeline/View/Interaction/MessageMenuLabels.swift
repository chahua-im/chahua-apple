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
        case .copy: hasAttachments ? String(localized: "Copy Text") : String(localized: "Copy")
        case .copyLink: String(localized: "Copy Link")
        case .reply: String(localized: "Reply")
        case .thread: String(localized: "Thread")
        case .pin: String(localized: "Pin")
        case .unpin: String(localized: "Unpin")
        case .edit: String(localized: "Edit")
        case .delete: String(localized: "Delete")
        case .save: String(localized: "Save")
        case .favorite: String(localized: "Favorite")
        case .reactionDetails: String(localized: "Reactions")
        }
    }
}
