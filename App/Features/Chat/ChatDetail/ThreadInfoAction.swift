import ChahuaAPI
import SwiftUI

/// The mounted thread owns participant coverage and its info sheet; the shell only
/// routes its floating-header Info button back to that live timeline instance.
struct ThreadInfoAction: Equatable {
    let conversation: ConversationKey
    let perform: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.conversation == rhs.conversation
    }
}

struct ThreadInfoActionKey: PreferenceKey {
    static let defaultValue: ThreadInfoAction? = nil

    static func reduce(value: inout ThreadInfoAction?, nextValue: () -> ThreadInfoAction?) {
        if let next = nextValue() { value = next }
    }
}
