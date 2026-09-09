import CryptoKit
import Foundation
import os

/// Temporary, opt-in diagnostics for avatar reappearance. No URLs or cache paths are emitted.
public enum AvatarCacheTrace {
    public static let enabled = ProcessInfo.processInfo.environment["CHAHUA_AVATAR_TRACE"] == "1"
        || ProcessInfo.processInfo.arguments.contains("-avatar-cache-trace")

    @TaskLocal public static var load: String?
    @TaskLocal static var transportKey: String?

    private static let logger = Logger(subsystem: "app.chahua.chat", category: "avatar-experiment")
    private static let origin = ContinuousClock.now
    private static let salt = UUID().uuidString

    public static func key(for request: MediaRequest) -> String? {
        guard enabled, request.tags.contains(CacheTag(rawValue: "avatars")),
              let normalized = try? request.normalized() else { return nil }
        return key(forNormalizedKey: normalized.key)
    }

    static func key(forNormalizedKey key: String) -> String {
        SHA256.hash(data: Data((salt + key).utf8)).prefix(6)
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func milliseconds(since start: ContinuousClock.Instant) -> String {
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
        return String(format: "%.3f", milliseconds)
    }

    public static func event(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        logger.notice("AVATAR_TRACE t_ms=\(milliseconds(since: origin), privacy: .public) load=\(load ?? "-", privacy: .public) \(text, privacy: .public)")
    }
}
