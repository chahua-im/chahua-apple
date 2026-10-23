import Foundation

extension ChahuaClient {
    public func notificationSettings() async throws -> NotificationSettingsResponse {
        try await send(
            HTTPRequestSpec(method: .get, path: ["users", "me", "notification-settings"]),
            decoding: NotificationSettingsResponse.self)
    }

    public func updateNotificationSettings(_ request: UpdateNotificationSettingsRequest)
        async throws
        -> NotificationSettingsResponse
    {
        try await send(
            HTTPRequestSpec.json(.patch, ["users", "me", "notification-settings"], body: request),
            decoding: NotificationSettingsResponse.self)
    }

    public func updateChatNotificationSetting(
        chatID: String, request: UpdateNotificationSettingRequest
    )
        async throws -> ChatNotificationSettingResponse
    {
        try await send(
            HTTPRequestSpec.json(.put, ["group", chatID, "notification-setting"], body: request),
            decoding: ChatNotificationSettingResponse.self)
    }

    public func notificationExceptions(kind: ChatKind, after: String?) async throws
        -> NotificationExceptionsResponse
    {
        var query = [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "limit", value: "20"),
        ]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        return try await send(
            HTTPRequestSpec(
                method: .get, path: ["users", "me", "notification-exceptions"], query: query),
            decoding: NotificationExceptionsResponse.self)
    }

    public func clearNotificationExceptions(kind: ChatKind) async throws
        -> NotificationExceptionsCleared
    {
        try await send(
            HTTPRequestSpec(
                method: .delete, path: ["users", "me", "notification-exceptions"],
                query: [URLQueryItem(name: "kind", value: kind.rawValue)]),
            decoding: NotificationExceptionsCleared.self)
    }
}

extension ChahuaAPIClient {
    public func notificationSettings() async throws -> NotificationSettingsResponse {
        throw APIError.unexpectedResponse
    }
    public func updateNotificationSettings(_ request: UpdateNotificationSettingsRequest)
        async throws
        -> NotificationSettingsResponse
    { throw APIError.unexpectedResponse }
    public func updateChatNotificationSetting(
        chatID: String, request: UpdateNotificationSettingRequest
    )
        async throws -> ChatNotificationSettingResponse
    { throw APIError.unexpectedResponse }
    public func notificationExceptions(kind: ChatKind, after: String?) async throws
        -> NotificationExceptionsResponse
    { throw APIError.unexpectedResponse }
    public func clearNotificationExceptions(kind: ChatKind) async throws
        -> NotificationExceptionsCleared
    {
        throw APIError.unexpectedResponse
    }
}
