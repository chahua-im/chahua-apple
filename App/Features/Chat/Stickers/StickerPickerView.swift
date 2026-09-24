import ChahuaAPI
import SwiftUI

struct StickerPickerView: View {
    @ObservedObject var library: StickerLibrary
    let isEnabled: Bool
    let onSelect: (MessageStickerResponse) async -> Bool
    @State private var selectedPackID: String?
    @State private var isSending = false

    private var stickers: [MessageStickerResponse] {
        guard let selectedPackID else { return library.favorites }
        return library.packDetails[selectedPackID]?.stickers ?? []
    }

    private var isLoading: Bool {
        if let selectedPackID { return library.loadingPackIDs.contains(selectedPackID) }
        return library.isLoading
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let error = library.error {
                HStack {
                    Text(error).font(.caption).lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await reload() } }
                }
                .padding(8)
            }
            ScrollView {
                if stickers.isEmpty {
                    Group {
                        if isLoading {
                            ProgressView("Loading stickers…")
                        } else {
                            Text(
                                selectedPackID == nil
                                    ? "No favorite stickers yet" : "No stickers in this pack"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
                        ForEach(stickers, id: \.id) { sticker in
                            Button {
                                guard !isSending else { return }
                                isSending = true
                                Task {
                                    _ = await onSelect(sticker)
                                    isSending = false
                                }
                            } label: {
                                StickerMediaView(media: sticker.media, emoji: sticker.emoji)
                                    .frame(width: 72, height: 72)
                                    .frame(maxWidth: .infinity, minHeight: 80)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!isEnabled || isSending)
                            .accessibilityLabel("Send \(sticker.name ?? sticker.emoji) sticker")
                            .contextMenu {
                                Button(
                                    library.isFavorite(sticker) ? "Unfavorite" : "Favorite",
                                    systemImage: library.isFavorite(sticker)
                                        ? "heart.slash" : "heart"
                                ) { Task { await library.toggleFavorite(sticker) } }
                                .disabled(library.pendingMutationIDs.contains(sticker.id))
                            }
                        }
                    }
                    .padding(8)
                }
            }
            Divider()
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    packTab(id: nil, name: AppLanguage.localized("Favorites")) {
                        Image(systemName: "heart.fill").font(.title3)
                    }
                    ForEach(library.packs) { pack in
                        packTab(id: pack.id, name: pack.name) {
                            if let preview = pack.previewSticker {
                                StickerMediaView(media: preview.media, emoji: preview.emoji)
                                    .frame(width: 32, height: 32)
                            } else {
                                Image(systemName: "square.stack").font(.title3)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .frame(height: 44)
        }
        .frame(height: 260)
        .background(.background)
        .task { await library.refresh() }
        .task(id: selectedPackID) {
            if let selectedPackID { _ = await library.loadPack(selectedPackID) }
        }
        .onChange(of: library.packs) { _, packs in
            if let selectedPackID, !packs.contains(where: { $0.id == selectedPackID }) {
                self.selectedPackID = nil
            }
        }
    }

    private func packTab<Content: View>(
        id: String?, name: String, @ViewBuilder content: () -> Content
    ) -> some View {
        Button {
            selectedPackID = id
        } label: {
            content()
                .frame(width: 44, height: 44)
                .background(
                    selectedPackID == id ? Color.accentColor.opacity(0.15) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selectedPackID == id ? .isSelected : [])
        .help(name)
    }

    private func reload() async {
        await library.refresh()
        if let selectedPackID { _ = await library.loadPack(selectedPackID, force: true) }
    }
}
