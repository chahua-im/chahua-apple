import ChahuaAPI
import SwiftUI

enum StickerShopStyle {
    static var canvas: Color {
        #if os(iOS)
            Color(uiColor: .systemGroupedBackground)
        #else
            Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    static var card: Color {
        #if os(iOS)
            Color(uiColor: .secondarySystemGroupedBackground)
        #else
            Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var tile: Color { Color.primary.opacity(0.035) }
}

struct StickerShopAddButton: View {
    @ObservedObject var library: StickerLibrary
    let pack: StickerPackSummary
    var compact = false
    var prominent = false
    var onEdit: (() -> Void)?
    @State private var showsFailure = false
    @Environment(\.controlSize) private var controlSize

    private var isOwned: Bool {
        pack.ownerUid == library.accountID || library.isOwnedPack(pack.id)
    }

    private var isPending: Bool { library.pendingMutationIDs.contains(pack.id) }
    private var usesTintedBackground: Bool { compact || pack.isSubscribed || isOwned }

    private var visualHeight: CGFloat {
        if compact {
            #if os(iOS)
                return 30
            #else
                return 24
            #endif
        }
        if prominent { return controlSize == .large ? 48 : 40 }
        return controlSize == .large ? 36 : 32
    }

    var body: some View {
        Button {
            if isOwned {
                onEdit?()
            } else {
                let accountID = library.accountID
                Task {
                    let added = await library.setSubscribed(true, pack: pack)
                    guard library.accountID == accountID else { return }
                    showsFailure = !added
                }
            }
        } label: {
            Group {
                if compact {
                    Image(systemName: isOwned ? "pencil" : pack.isSubscribed ? "checkmark" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                } else {
                    HStack(spacing: 4) {
                        if !isOwned && (pack.isSubscribed || prominent) {
                            Image(systemName: pack.isSubscribed ? "checkmark" : "plus")
                        }
                        if isOwned {
                            Text(prominent ? LocalizedStringKey("Manage Pack") : "Your pack")
                        } else if pack.isSubscribed {
                            Text("Added")
                        } else {
                            Text(prominent ? LocalizedStringKey("Add Pack") : "Add")
                        }
                    }
                    .font(
                        .system(
                            size: prominent && controlSize == .large ? 17 : 15, weight: .semibold)
                    )
                    .padding(.horizontal, prominent ? 20 : 16)
                }
            }
            .opacity(isPending ? 0 : 1)
            .overlay {
                if isPending {
                    ProgressView().controlSize(.small)
                        .tint(usesTintedBackground ? Color.accentColor : .white)
                }
            }
            .frame(minWidth: compact ? visualHeight : 48)
            .frame(height: visualHeight)
            .foregroundStyle(usesTintedBackground ? Color.accentColor : .white)
            .background(
                usesTintedBackground ? Color.accentColor.opacity(0.1) : Color.accentColor,
                in: Capsule()
            )
            #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
            #endif
            .contentShape(Rectangle())
        }
        .buttonStyle(StickerShopAddButtonStyle())
        .disabled(
            isPending || library.accountID == nil || (!isOwned && pack.isSubscribed)
                || (isOwned && onEdit == nil)
        )
        .accessibilityLabel(
            isOwned ? Text("Manage Pack") : pack.isSubscribed ? Text("Added") : Text("Add Pack")
        )
        .accessibilityIdentifier("sticker-shop.add.\(pack.id)")
        .popover(isPresented: $showsFailure) {
            Text("Couldn’t add sticker pack. Try again.")
                .font(.callout)
                .padding()
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: library.accountID) { _, _ in showsFailure = false }
        .onChange(of: pack.isSubscribed) { _, subscribed in
            if subscribed { showsFailure = false }
        }
    }
}

private struct StickerShopAddButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Added/pending retain their status colors while disabled against duplicate requests.
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}
