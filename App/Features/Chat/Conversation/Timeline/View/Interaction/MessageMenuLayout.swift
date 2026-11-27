import CoreGraphics
import Foundation

/// The same compact menu geometry is used by native controls on both platforms.
enum MessageMenuLayout {
    static let width: CGFloat = 276
    static let padding: CGFloat = 6
    static let radius: CGFloat = 16
    static let gap: CGFloat = 8
    static let columns = 5
    static let rowHeight: CGFloat = 63
    static let reactionTarget: CGFloat = 44
    static let reactionHeight: CGFloat = 56
    static let actionIcon: CGFloat = 23
    static let labelSize: CGFloat = 11
    static let labelLineHeight: CGFloat = 12
    static let labelGap: CGFloat = 7

    /// SF Symbols have different intrinsic proportions. Fit them into a common
    /// icon box without stretching either axis or changing the label's geometry.
    static func symbolRect(for imageSize: CGSize, in box: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: box.origin, size: .zero)
        }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: box.midX - size.width / 2, y: box.midY - size.height / 2,
            width: size.width, height: size.height)
    }
}

/// Two rows remain stable while the navigation control changes the visible actions.
/// The second page repeats the preceding row when space permits, as in the design.
struct MessageMenuPage {
    let actions: ArraySlice<MessageMenuAction>
    let page: Int
    let hasNavigation: Bool

    init(actions: [MessageMenuAction], page: Int) {
        hasNavigation = actions.count > 10
        self.page = hasNavigation && page > 0 ? 1 : 0
        if !hasNavigation {
            self.actions = actions[...]
        } else if self.page == 0 {
            self.actions = actions.prefix(9)
        } else {
            // Repeat at most four actions, never displace an otherwise unreachable action.
            self.actions = actions.suffix(from: max(5, actions.count - 9))
        }
    }

    var navigationSlot: Int? { hasNavigation ? (page == 0 ? 9 : 4) : nil }
    var navigationSymbol: String { page == 0 ? "chevron.down" : "chevron.up" }
    var navigationLabel: String {
        page == 0
            ? AppLanguage.localized("More actions") : AppLanguage.localized("Previous actions")
    }
    var nextPage: Int { page == 0 ? 1 : 0 }
}
