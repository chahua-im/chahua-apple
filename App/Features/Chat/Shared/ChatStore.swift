import Combine
import ChahuaAPI

@MainActor
enum ChatListLoadPhase: Equatable {
    case idle
    case loading
    case loaded
    case failed
}

struct ChatState: Equatable {
    var chats: [ChatListItem] = []
    var messagesByChatID: [String: [String: MessageResponse]] = [:]
    var chatListLoadPhase: ChatListLoadPhase = .idle
}

@MainActor
final class ChatStore: ObservableObject {
    @Published private(set) var state = ChatState()

    private let apiClient: any ChahuaAPIClient
    private let onInvalidToken: @MainActor @Sendable () async -> Void
    private var generation = 0

    init(
        apiClient: any ChahuaAPIClient,
        onInvalidToken: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.apiClient = apiClient
        self.onInvalidToken = onInvalidToken
    }

    func loadActiveChats() async {
        guard state.chatListLoadPhase == .idle || state.chatListLoadPhase == .failed else { return }

        let requestGeneration = generation
        state.chatListLoadPhase = .loading

        do {
            let response = try await apiClient.listChats(query: ListChatsQuery(archived: false))
            guard generation == requestGeneration else { return }
            state.chats = response.chats
            state.chatListLoadPhase = .loaded
        } catch is CancellationError {
            guard generation == requestGeneration else { return }
            state.chatListLoadPhase = .idle
        } catch APIError.invalidToken {
            guard generation == requestGeneration else { return }
            state.chatListLoadPhase = .failed
            await onInvalidToken()
        } catch {
            guard generation == requestGeneration else { return }
            state.chatListLoadPhase = .failed
        }
    }

    func fetchMessages(
        chatID: String,
        query: ListMessagesQuery = .init()
    ) async throws -> ListMessagesResponse {
        let requestGeneration = generation
        do {
            let response = try await apiClient.listMessages(chatID: chatID, query: query)
            guard generation == requestGeneration else { throw CancellationError() }
            cache(response.messages)
            return response
        } catch APIError.invalidToken {
            await onInvalidToken()
            throw APIError.invalidToken
        }
    }

    func cache(_ messages: [MessageResponse]) {
        for message in messages {
            state.messagesByChatID[message.chatId, default: [:]][message.id] = message
        }
    }

    func reset() {
        generation += 1
        state = ChatState()
    }
}
