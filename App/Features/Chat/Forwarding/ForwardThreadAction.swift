import ChahuaAPI
import SwiftUI

/// The visible thread supplies its current forwarding action to the shell-owned header.
struct ForwardThreadAction: Equatable {
    let conversation: ConversationKey
    let count: Int64
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation == rhs.conversation && lhs.count == rhs.count
    }
}

struct ForwardThreadActionKey: PreferenceKey {
    static let defaultValue: ForwardThreadAction? = nil
    static func reduce(value: inout ForwardThreadAction?, nextValue: () -> ForwardThreadAction?) {
        if let next = nextValue() { value = next }
    }
}
