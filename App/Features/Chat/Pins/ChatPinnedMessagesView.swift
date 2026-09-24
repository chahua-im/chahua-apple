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
    let onJump: () -> Void
    let onShowAll: () -> Void
    var onOpenThread: (() -> Void)?
    var onUnpin: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onJump) {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pinned Message")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text(pinPreview(pin.message))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Jump to pinned message")

            if let onOpenThread {
                Button(action: onOpenThread) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .frame(width: 36, height: 44)
                }
                .accessibilityLabel("Open thread")
            }
            Button(action: onShowAll) {
                HStack(spacing: 4) {
                    Image(systemName: "list.dash")
                    Text(count, format: .number).font(.caption.monospacedDigit())
                }
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 6)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("View all pinned messages")
            .accessibilityValue(Text(count, format: .number))
        }
        .buttonStyle(.plain)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .modifier(ChatGlassSurface(cornerRadius: 24))
        .contextMenu {
            Button("View all pinned messages", action: onShowAll)
            if let onUnpin {
                Button("Unpin", role: .destructive, action: onUnpin)
            }
        }
    }
}

/// The shell supplies the title inset. Add the pin bar's measured height rather
/// than changing the native navigation bar or covering the timeline's first row.
struct ChatPinnedBarOverlay<Bar: View>: ViewModifier {
    let isVisible: Bool
    @ViewBuilder let bar: () -> Bar
    @Environment(\.chatHeaderInset) private var titleInset
    @State private var barHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.chatHeaderInset, titleInset + (isVisible ? barHeight + 12 : 0))
            .overlay(alignment: .top) {
                if isVisible {
                    bar()
                        .background {
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { barHeight = geometry.size.height }
                                    .onChange(of: geometry.size.height) { _, height in
                                        barHeight = height
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, titleInset)
                }
            }
    }
}

struct ChatPinnedMessagesSheet: View {
    let chatID: String
    @ObservedObject var controller: ChatPinController
    let canManage: Bool
    let onSelect: (MessageResponse) -> Void
    var onOpenThread: ((MessageResponse) -> Void)?
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
                                    Text(messagePreview(pin.message.replyPreview))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
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

private func pinPreview(_ message: MessageResponse) -> String {
    let sender = message.sender.name ?? "User \(message.sender.uid)"
    let preview = messagePreview(message.replyPreview)
    return "\(sender): \(preview.isEmpty ? AppLanguage.localized("Message") : preview)"
}
