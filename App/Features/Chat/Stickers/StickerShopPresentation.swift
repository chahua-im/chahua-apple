import SwiftUI

extension View {
    func stickerShop(isPresented: Binding<Bool>, library: StickerLibrary) -> some View {
        modifier(StickerShopPresentation(isPresented: isPresented, library: library))
    }
}

private struct StickerShopPresentation: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var library: StickerLibrary
    #if os(iOS)
        @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
            if sizeClass == .compact {
                content.fullScreenCover(isPresented: $isPresented) {
                    StickerShopSheet(library: library)
                }
            } else {
                content.sheet(isPresented: $isPresented) {
                    wideSheet
                }
            }
        #else
            content.sheet(isPresented: $isPresented) {
                StickerShopSheet(library: library)
                    .frame(width: 980, height: 720)
            }
        #endif
    }

    #if os(iOS)
        @ViewBuilder
        private var wideSheet: some View {
            if #available(iOS 18, *) {
                // New SDKs default to form sizing; the shop needs a large page sheet.
                wideSheetContent.presentationSizing(.page)
            } else {
                wideSheetContent
            }
        }

        private var wideSheetContent: some View {
            StickerShopSheet(library: library)
                .frame(minWidth: 720, idealWidth: 1060, minHeight: 540, idealHeight: 784)
                .presentationDetents([.large])
        }
    #endif
}

private struct StickerShopSheet: View {
    @ObservedObject var library: StickerLibrary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            StickerDiscoveryView(library: library, onClose: { dismiss() })
        }
    }
}
