import Foundation

/// APNs delivery environment selected by the app's signing entitlement.
public enum APNsEnvironment: String, Codable, Sendable {
    case sandbox
    case production
}

public protocol PushSubscriptionProviding: Sendable {
    func subscribeToPush(deviceToken: String, environment: APNsEnvironment) async throws
    func unsubscribeFromPush(deviceToken: String, environment: APNsEnvironment) async throws
}

private struct PushSubscriptionBody: Encodable {
    let provider = "apns"
    let deviceToken: String
    let environment: APNsEnvironment
}

extension ChahuaClient: PushSubscriptionProviding {
    /// Associates this APNs token with the user and installation in the session JWT.
    /// The backend returns an empty 201 response.
    public func subscribeToPush(deviceToken: String, environment: APNsEnvironment) async throws {
        try await send(
            HTTPRequestSpec.json(
                .post,
                ["push", "subscribe"],
                body: PushSubscriptionBody(deviceToken: deviceToken, environment: environment)
            )
        )
    }

    /// Removes only the matching token/environment owned by the authenticated session.
    /// The backend returns an empty 200 response, including when already unsubscribed.
    public func unsubscribeFromPush(deviceToken: String, environment: APNsEnvironment) async throws
    {
        try await send(
            HTTPRequestSpec.json(
                .post,
                ["push", "unsubscribe"],
                body: PushSubscriptionBody(deviceToken: deviceToken, environment: environment)
            )
        )
    }
}
