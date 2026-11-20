import ChahuaAPI
import SwiftUI

/// The PWA follows the newest pin at or above the viewport's bottom message.
enum ChatPinSelection {
    static func activePin(in pins: [PinResponse], bottomVisibleMessageDate: Date?) -> PinResponse? {
        guard let bottomVisibleMessageDate else { return pins.first }
        return pins.first { $0.message.createdAt <= bottomVisibleMessageDate } ?? pins.last
    }
}

struct ChatPinnedMessageBar: View {
    let pin: PinResponse
    let count: Int
    var position: Int? = nil
    let onJump: () -> Void
    let onShowAll: () -> Void
    var onOpenThread: (() -> Void)?
    var onUnpin: (() -> Void)?
    @Environment(\.isWideChatLayout) private var isWideChatLayout

    private var controlHeight: CGFloat {
        #if os(macOS)
            36
        #else
            44
        #endif
    }

    private var barCornerRadius: CGFloat {
        #if os(macOS)
            18
        #else
            isWideChatLayout ? 22 : 24
        #endif
    }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onJump) {
                HStack(spacing: 10) {
                    if isWideChatLayout {
                        Image(systemName: "pin")
                            .foregroundStyle(Color.accentColor)
                        Text("Pinned")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                        Text("·")
                            .foregroundStyle(.secondary)
                        pinPreview(pin.message)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Pinned Message")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                            pinPreview(pin.message)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(minHeight: isWideChatLayout ? controlHeight : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Jump to pinned message")

            if let onOpenThread {
                Button(action: onOpenThread) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .frame(width: 36, height: controlHeight)
                }
                .accessibilityLabel("Open thread")
            }
            Button(action: onShowAll) {
                HStack(spacing: 4) {
                    if isWideChatLayout, let position {
                        Text("\(position) of \(count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        #if os(macOS)
                            Image(systemName: "list.dash")
                                .frame(width: 26, height: 26)
                                .accessibilityHidden(true)
                        #endif
                    } else {
                        Image(systemName: "list.dash")
                        Text(count, format: .number).font(.caption.monospacedDigit())
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: controlHeight)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("View all pinned messages")
            .accessibilityValue(Text(count, format: .number))
        }
        .buttonStyle(.plain)
        .font(isWideChatLayout ? .subheadline : nil)
        #if os(macOS)
            .font(.system(size: 13))
        #endif
        .padding(.leading, isWideChatLayout ? 16 : 14)
        .padding(.trailing, 8)
        .padding(.vertical, isWideChatLayout ? 0 : 6)
        .modifier(
            ChatGlassSurface(
                shape: RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
        )
        .contextMenu {
            Button("View all pinned messages", action: onShowAll)
            if let onUnpin {
                Button("Unpin", role: .destructive, action: onUnpin)
            }
        }
    }
}

enum ChatSecondaryHeaderKind: Equatable {
    case pins, playback

    static func select(needsPlayback: Bool, hasPins: Bool) -> Self? {
        if needsPlayback { return .playback }
        return hasPins ? .pins : nil
    }

    var bottomGap: CGFloat { self == .playback ? 8 : 12 }
}

/// Only the winning bar obscures rows. Both eligible bars contribute to one
/// stable scroll limit so switching the winner never changes native scroll geometry.
struct ChatSecondaryHeaderOverlay<Pins: View, Playback: View>: ViewModifier {
    let kind: ChatSecondaryHeaderKind?
    var pinsEligible = false
    var playbackEligible = false
    @ViewBuilder let pins: () -> Pins
    @ViewBuilder let playback: () -> Playback
    @Environment(\.isWideChatLayout) private var isWideChatLayout
    @Environment(\.chatHeaderInset) private var titleInset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pinsHeight: CGFloat?
    @State private var playbackHeight: CGFloat?

    private var nominalPinsHeight: CGFloat {
        #if os(macOS)
            36
        #else
            isWideChatLayout ? 44 : 56
        #endif
    }

    private var horizontalInset: CGFloat {
        #if os(macOS)
            isWideChatLayout ? 16 : 12
        #else
            isWideChatLayout ? 20 : 12
        #endif
    }

    private func clearance(for kind: ChatSecondaryHeaderKind?) -> CGFloat {
        switch kind {
        case .pins: (pinsHeight ?? nominalPinsHeight) + ChatSecondaryHeaderKind.pins.bottomGap
        case .playback:
            (playbackHeight ?? VoicePlaybackCapsule.nominalHeight)
                + ChatSecondaryHeaderKind.playback.bottomGap
        case nil: 0
        }
    }

    func body(content: Content) -> some View {
        let visibleInset = titleInset + clearance(for: kind)
        let pinInset = clearance(for: pinsEligible ? .pins : nil)
        let scrollInset =
            playbackEligible
            ? titleInset + max(pinInset, clearance(for: .playback)) : visibleInset
        content
            .environment(\.chatHeaderInset, visibleInset)
            .environment(\.chatScrollHeaderInset, scrollInset)
            .environment(\.voiceReferenceHeaderInset, titleInset + pinInset)
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if pinsEligible {
                        pins()
                            .modifier(SecondaryHeaderVisibility(isVisible: kind == .pins))
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                                if $0 > 0 { pinsHeight = $0 }
                            }
                    }
                    if playbackEligible || kind == .playback {
                        playback()
                            .modifier(SecondaryHeaderVisibility(isVisible: kind == .playback))
                            .offset(y: kind == .playback || reduceMotion ? 0 : -10)
                            .fixedSize(horizontal: false, vertical: true)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                                if $0 > 0 { playbackHeight = $0 }
                            }
                            .animation(
                                VoicePlaybackMotion.animation(
                                    showing: kind == .playback, reduceMotion: reduceMotion),
                                value: kind == .playback
                            )
                            .transition(VoicePlaybackMotion.transition)
                    }
                }
                .padding(.horizontal, horizontalInset)
                .padding(.top, titleInset)
            }
    }
}

private struct SecondaryHeaderVisibility: ViewModifier {
    let isVisible: Bool

    func body(content: Content) -> some View {
        content.opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}

struct ChatPinnedMessagesSheet: View {
    let chatID: String
    @ObservedObject var controller: ChatPinController
    let canManage: Bool
    let onSelect: (MessageResponse) -> Void
    var onOpenThread: ((MessageResponse) -> Void)?
    var showsVoiceHeader = false
    @Environment(\.dismiss) private var dismiss
    @State private var pinToUnpin: PinResponse?

    private var pins: [PinResponse] { controller.pinsByChatID[chatID] ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if controller.failedChatIDs.contains(chatID) {
                    Button("Couldn’t load pinned messages. Retry") {
                        Task { await controller.load(chatID: chatID, force: true) }
                    }
                }
                if pins.isEmpty {
                    if controller.loadingChatIDs.contains(chatID) {
                        ProgressView("Loading pinned messages…")
                    } else if !controller.failedChatIDs.contains(chatID) {
                        Text("No pinned messages").foregroundStyle(.secondary)
                    }
                }
                ForEach(pins, id: \.id) { pin in
                    HStack(spacing: 12) {
                        Button {
                            dismiss()
                            onSelect(pin.message)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(
                                    url: pin.message.sender.avatarUrl.flatMap(URL.init(string:)),
                                    displayName: pin.message.sender.name
                                        ?? "User \(pin.message.sender.uid)", diameter: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(
                                        pin.message.sender.name ?? "User \(pin.message.sender.uid)"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    MessageSummaryText(
                                        pin.message.replyPreview, color: .secondary, lineLimit: 2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if pin.message.threadInfo != nil, let onOpenThread {
                            Button {
                                dismiss()
                                onOpenThread(pin.message)
                            } label: {
                                Image(systemName: "bubble.left.and.bubble.right")
                            }
                            .accessibilityLabel("Open thread")
                        }
                        if canManage {
                            Button("Unpin", role: .destructive) { pinToUnpin = pin }
                                .disabled(controller.pendingMessageIDs.contains(pin.message.id))
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .navigationTitle("Pinned Messages")
            .voicePlaybackHeader(enabled: showsVoiceHeader)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .refreshable { await controller.load(chatID: chatID, force: true) }
            .alert(
                "Unpin Message",
                isPresented: Binding(
                    get: { pinToUnpin != nil }, set: { if !$0 { pinToUnpin = nil } }
                )
            ) {
                if let pin = pinToUnpin {
                    Button("Unpin", role: .destructive) { Task { await controller.unpin(pin) } }
                }
                Button("Cancel", role: .cancel) { pinToUnpin = nil }
            } message: {
                Text("Would you like to unpin this message?")
            }
            .alert(
                "Pinned messages",
                isPresented: Binding(
                    get: { controller.error != nil }, set: { if !$0 { controller.error = nil } }
                )
            ) {
                Button("OK") { controller.error = nil }
            } message: {
                Text(controller.error ?? "")
            }
        }
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #else
            .frame(minWidth: 420, minHeight: 360)
        #endif
    }
}

private func pinPreview(_ message: MessageResponse) -> some View {
    let sender = message.sender.name ?? "User \(message.sender.uid)"
    return MessageSummaryText(
        message.replyPreview, prefix: sender + ": ", fallback: AppLanguage.localized("Message"))
}
