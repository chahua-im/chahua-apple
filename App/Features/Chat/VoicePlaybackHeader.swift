import ChahuaAPI
import SwiftUI

struct VoicePlaybackHeaderRoute {
    let currentUserID: Int32
    let chatName: (String) -> String?
    let open: (MessageResponse, @escaping () -> Void, @escaping () -> Void) -> Void

    func dismissing(_ dismiss: @escaping () -> Void) -> Self {
        Self(currentUserID: currentUserID, chatName: chatName) { message, accepted, unavailable in
            open(
                message,
                {
                    accepted()
                    dismiss()
                }, unavailable)
        }
    }

    func guarded(by requestExit: @escaping (@escaping () -> Void) -> Void) -> Self {
        Self(currentUserID: currentUserID, chatName: chatName) { message, accepted, unavailable in
            requestExit { open(message, accepted, unavailable) }
        }
    }
}

extension EnvironmentValues {
    @Entry var voicePlaybackHeaderRoute: VoicePlaybackHeaderRoute? = nil
    @Entry var isVoicePlaybackHeaderCovered = false
}

/// A sheet owned by a descendant (for example, the composer) covers the same timeline.
struct VoicePlaybackCoverPreference: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    func voicePlaybackHeader(floating: Bool = false, enabled: Bool = true) -> some View {
        modifier(VoicePlaybackHeader(floating: floating, enabled: enabled))
    }

    func voicePlaybackCovered(_ covered: Bool) -> some View {
        transformEnvironment(\.isVoicePlaybackHeaderCovered) { $0 = $0 || covered }
    }

    func voicePlaybackCover(onOpen: @escaping () -> Void) -> some View {
        transformEnvironment(\.voicePlaybackHeaderRoute) { $0 = $0?.dismissing(onOpen) }
            .environment(\.isVoicePlaybackHeaderCovered, false)
    }
}

private struct VoicePlaybackHeader: ViewModifier {
    let floating: Bool
    let enabled: Bool
    @Environment(\.voicePlaybackHeaderRoute) private var route
    @Environment(\.isVoicePlaybackHeaderCovered) private var isCovered
    @ObservedObject private var session = VoicePlaybackSession.shared

    func body(content: Content) -> some View {
        let controller = enabled && route != nil && !isCovered ? session.controller : nil
        if floating {
            content.modifier(
                ChatSecondaryHeaderOverlay(kind: controller == nil ? nil : .playback) {
                    EmptyView()
                } playback: {
                    if let controller {
                        VoicePlaybackBar(controller: controller)
                    }
                })
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) {
                VoicePlaybackHeaderRow(isEnabled: enabled)
            }
        }
    }
}

struct VoicePlaybackHeaderRow: View {
    var isEnabled = true
    @Environment(\.voicePlaybackHeaderRoute) private var route
    @Environment(\.isVoicePlaybackHeaderCovered) private var isCovered
    @ObservedObject private var session = VoicePlaybackSession.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let controller = isEnabled && route != nil && !isCovered ? session.controller : nil
        Group {
            if let controller {
                VoicePlaybackBar(controller: controller)
                    .padding(.horizontal, 12)
                    .padding(.bottom, ChatSecondaryHeaderKind.playback.bottomGap)
                    .transition(VoicePlaybackMotion.transition)
            }
        }
        .animation(
            VoicePlaybackMotion.animation(showing: controller != nil, reduceMotion: reduceMotion),
            value: controller != nil)
    }
}
