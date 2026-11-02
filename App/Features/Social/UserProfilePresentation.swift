import ChahuaAPI
import SwiftUI

#if os(iOS)
    import UIKit
#endif

/// Profiles are independent cards on Mac/iPad, never pages inside a chat inspector.
/// Compact iPhone retains native pushed navigation.
struct UserProfilePresentation: ViewModifier {
    @Binding var uid: Int32?
    let currentUserID: Int32
    let store: ChatStore
    let onOpenChat: (ChatListItem) -> Void

    static var usesModal: Bool {
        #if os(macOS)
            true
        #else
            UIDevice.current.userInterfaceIdiom == .pad
        #endif
    }

    func body(content: Content) -> some View {
        if Self.usesModal {
            content.sheet(
                isPresented: Binding(
                    get: { uid != nil }, set: { if !$0 { uid = nil } }
                )
            ) {
                if let uid {
                    NavigationStack {
                        UserProfileView(
                            uid: uid, currentUserID: currentUserID, store: store,
                            onClose: { self.uid = nil },
                            onOpenChat: { chat in
                                self.uid = nil
                                onOpenChat(chat)
                            })
                    }
                    .id(uid)
                    .modifier(ProfileModalSizing())
                }
            }
        } else {
            content.navigationDestination(item: $uid) { uid in
                UserProfileView(
                    uid: uid, currentUserID: currentUserID, store: store,
                    onOpenChat: onOpenChat)
            }
        }
    }
}

struct ProfileModalSizing: ViewModifier {
    private var idealHeight: CGFloat {
        #if os(macOS)
            290
        #else
            304
        #endif
    }
    func body(content: Content) -> some View {
        if !UserProfilePresentation.usesModal {
            content.frame(minWidth: 320, minHeight: 420)
        } else if #available(iOS 18, macOS 15, *) {
            content
                .frame(
                    minWidth: 320, idealWidth: 380, maxWidth: 460,
                    minHeight: 260, idealHeight: idealHeight, maxHeight: 640
                )
                .presentationSizing(.fitted)
                .presentationCornerRadius(20)
        } else {
            content.frame(minWidth: 320, idealWidth: 380, minHeight: 340)
                .presentationCornerRadius(20)
        }
    }
}
