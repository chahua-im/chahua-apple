import ChahuaAPI
import SwiftUI

struct StickerPackSheet: View {
    let stickerID: String
    @ObservedObject var library: StickerLibrary
    let currentUserID: Int32
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSticker: MessageStickerResponse?
    @State private var packID: String?
    @State private var isLoading = true
    @State private var hasLoaded = false

    private var packDetail: StickerPackDetailResponse? {
        guard let packID else { return nil }
        return library.packDetails[packID]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let sticker = selectedSticker {
                        StickerMediaView(media: sticker.media, emoji: sticker.emoji)
                            .frame(width: 176, height: 176)
                            .accessibilityLabel(sticker.name ?? sticker.emoji)
                        Text(sticker.emoji).font(.title2)
                        if let pack = packDetail?.pack {
                            VStack(spacing: 4) {
                                Text(pack.name).font(.headline)
                                Text("\(pack.stickerCount) stickers").font(.subheadline).foregroundStyle(.secondary)
                                if let description = pack.description, !description.isEmpty {
                                    Text(description).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .multilineTextAlignment(.center)
                        }
                        HStack {
                            Button {
                                Task { await library.toggleFavorite(sticker) }
                            } label: {
                                Label(
                                    library.isFavorite(sticker) ? "Unfavorite" : "Favorite",
                                    systemImage: library.isFavorite(sticker) ? "heart.fill" : "heart"
                                )
                            }
                            .disabled(library.pendingMutationIDs.contains(sticker.id))
                            if let pack = packDetail?.pack, pack.ownerUid != currentUserID {
                                Button(pack.isSubscribed ? "Unsubscribe" : "Subscribe") {
                                    Task { _ = await library.setSubscribed(!pack.isSubscribed, pack: pack) }
                                }
                                .disabled(library.pendingMutationIDs.contains(pack.id))
                            }
                        }
                        .buttonStyle(.bordered)
                        if let detail = packDetail {
                            Divider()
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 80), spacing: 4)], spacing: 4) {
                                ForEach(detail.stickers, id: \.id) { item in
                                    Button { selectedSticker = item } label: {
                                        StickerMediaView(media: item.media, emoji: item.emoji)
                                            .frame(width: 72, height: 72)
                                            .frame(maxWidth: .infinity, minHeight: 80)
                                            .background(selectedSticker?.id == item.id ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.name ?? item.emoji)
                                    .accessibilityAddTraits(selectedSticker?.id == item.id ? .isSelected : [])
                                }
                            }
                        } else if hasLoaded, packID == nil {
                            Text("This sticker is not part of any pack")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    if isLoading { ProgressView("Loading sticker pack…") }
                    if let error = library.error {
                        VStack(spacing: 8) {
                            Text(error).font(.subheadline).foregroundStyle(.secondary)
                            Button("Retry") { Task { await load(force: true) } }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .navigationTitle("Stickers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 620)
        #else
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
        .task(id: stickerID) { await load() }
    }

    private func load(force: Bool = false) async {
        guard !hasLoaded || force else { return }
        isLoading = true
        defer { isLoading = false }
        guard let detail = await library.loadSticker(stickerID), !Task.isCancelled else { return }
        selectedSticker = detail.sticker
        packID = detail.packs.first?.id
        if let packID { _ = await library.loadPack(packID, force: force) }
        hasLoaded = true
    }
}
