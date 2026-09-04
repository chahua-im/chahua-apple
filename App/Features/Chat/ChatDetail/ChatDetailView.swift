import ChahuaAPI
import SwiftUI

struct ChatDetailView: View {
    let chat: ChatListItem
    @StateObject private var model: ConversationTimelineModel

    init(chat: ChatListItem, currentUserID: Int32, store: ChatStore) {
        self.chat = chat
        _model = StateObject(wrappedValue: ConversationTimelineModel(
            chatID: chat.id,
            currentUserID: currentUserID,
            isGroupChat: chat.kind == .group,
            source: store,
            messageStore: store.conversationMessages
        ))
    }

    var body: some View {
        ConversationTimelineView(model: model)
            .navigationTitle(chat.chatDisplayName)
    }
}
