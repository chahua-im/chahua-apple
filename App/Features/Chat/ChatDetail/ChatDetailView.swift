import ChahuaAPI
import SwiftUI

struct ChatDetailView: View {
    let chat: ChatListItem
    private let store: ChatStore
    @StateObject private var model: ConversationTimelineModel

    init(chat: ChatListItem, currentUserID: Int32, store: ChatStore) {
        self.chat = chat
        self.store = store
        _model = StateObject(wrappedValue: ConversationTimelineModel(
            chatID: chat.id,
            currentUserID: currentUserID,
            isGroupChat: chat.kind == .group,
            source: store,
            messageStore: store.conversationMessages
        ))
    }

    var body: some View {
        ConversationTimelineView(model: model, loadsInitialAutomatically: false)
            .navigationTitle(chat.chatDisplayName)
            .onAppear { store.registerTimeline(model) }
            .task { await model.open() }
            .onDisappear {
                store.unregisterTimeline(model)
                model.close()
            }
    }
}
