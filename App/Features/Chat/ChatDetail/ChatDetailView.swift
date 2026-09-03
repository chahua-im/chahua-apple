import ChahuaAPI
import SwiftUI

/// Navigation destination for a chat. The conversation timeline is added here
/// in the next feature slice.
struct ChatDetailView: View {
    let chat: ChatListItem

    var body: some View {
        VStack(spacing: ChahuaTheme.Spacing.medium) {
            AvatarView(
                url: chat.chatAvatarURL,
                displayName: chat.chatDisplayName,
                diameter: 80
            )
            Text(chat.chatDisplayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .navigationTitle(chat.chatDisplayName)
    }
}
