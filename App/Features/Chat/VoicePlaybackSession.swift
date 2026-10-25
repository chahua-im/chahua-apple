import ChahuaAPI
import Combine
import Foundation

/// Authenticated shell playback ownership. Rows can disappear or be recycled without
/// owning the active player's lifetime; recording previews remain local controllers.
@MainActor
final class VoicePlaybackSession: ObservableObject {
    static let shared = VoicePlaybackSession()
    @Published private(set) var controller: VoicePlaybackController?
    @Published private(set) var speed: Float
    static let speeds: [Float] = [1, 1.25, 1.5, 1.75, 2]
    private static let speedKey = "voicePlaybackSpeed"

    private init() {
        let saved = UserDefaults.standard.float(forKey: Self.speedKey)
        speed = Self.speeds.contains(saved) ? saved : 1
    }

    func adopt(_ controller: VoicePlaybackController) {
        guard self.controller !== controller else { return }
        let previous = self.controller
        self.controller = controller
        // A still-mounted row keeps its prepared player and can resume immediately.
        // If no row owns it, releasing the session reference lets deinit clean it up.
        previous?.pause()
        controller.setSpeed(speed)
    }

    func remove(_ controller: VoicePlaybackController) {
        if self.controller === controller { self.controller = nil }
    }

    func setSpeed(_ speed: Float) {
        guard Self.speeds.contains(speed) else { return }
        self.speed = speed
        UserDefaults.standard.set(speed, forKey: Self.speedKey)
        controller?.setSpeed(speed)
    }

    func dismiss() {
        let previous = controller
        controller = nil
        previous?.pause()
    }

    /// Call at sign-out/account invalidation, not when navigating away from a chat.
    func stop() {
        let previous = controller
        controller = nil
        previous?.stop()
    }
}
