import ChahuaAPI
import Combine
import ImageIO
import SwiftUI

/// Shared by the compose bar and the attachment dialog's actual caption.
struct DraftLinkPreviewControls: View {
    @ObservedObject var state: DraftLinkPreviewState
    var isEnabled = true
    let onOpen: () -> Void

    var body: some View {
        if !state.urls.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onOpen) {
                    Image(systemName: "link")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 36, height: 32)
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 9, weight: .bold))
                                .padding(3)
                                .background(.regularMaterial, in: Circle())
                        }
                }
                .foregroundStyle(ChahuaTheme.accent)
                .accessibilityLabel("Link previews")
                .disabled(!isEnabled)
                .modifier(ComposerSendFocus())
                if let preview = state.firstReady {
                    DraftLinkPreviewCard(preview: preview)
                } else if let fallback = state.fallbackURL, let url = URL(string: fallback) {
                    Link(destination: url) {
                        Label(fallback, systemImage: "link")
                            .font(.callout).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

struct DraftLinkPreviewManagement: View {
    @ObservedObject var state: DraftLinkPreviewState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(state.urls, id: \.self) { url in
                        entry(url)
                    }
                }
                .padding()
            }
            .navigationTitle("Link previews")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .automatic) {
                    Text("\(state.selected.count)/3").foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 300, idealWidth: 420, minHeight: 300, idealHeight: 480)
        .presentationDetents([.medium, .large])
        .onAppear { state.setManagementOpen(true) }
        .onDisappear { state.setManagementOpen(false) }
    }

    private func entry(_ url: String) -> some View {
        let active = state.selected.contains(url)
        let disabled = state.isDisabled(url)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                if let preview = state.results[url], preview.status == .ready {
                    DraftLinkPreviewCard(preview: preview)
                } else if let destination = URL(string: url) {
                    Link(destination: destination) {
                        HStack(spacing: 10) {
                            if active && state.pending.contains(url) {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "link")
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(destination.host ?? url).font(.callout.weight(.semibold))
                                Text(url).font(.caption).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                if !disabled && !active {
                    Text("Only the first 3 enabled links have previews.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if active && state.results[url]?.status == .unavailable {
                    Text("Preview unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(active ? 1 : 0.5)
            Button {
                state.toggle(url)
            } label: {
                Image(systemName: disabled ? "circle" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(disabled ? Color.secondary : ChahuaTheme.accent)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(disabled ? "Enable link preview" : "Disable link preview")
        }
        .buttonStyle(.plain)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct DraftLinkPreviewCard: View {
    let preview: MessageLinkPreview

    var body: some View {
        if let url = URL(string: preview.url) {
            Link(destination: url) {
                HStack(alignment: .top, spacing: 10) {
                    if let image = preview.image {
                        DraftLinkPreviewThumbnail(source: image.url)
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            preview.title.flatMap { $0.isEmpty ? nil : $0 } ?? url.host
                                ?? preview.url
                        )
                        .font(.callout.weight(.semibold)).lineLimit(2)
                        if let description = preview.description, !description.isEmpty {
                            Text(description).font(.caption).lineLimit(3)
                        }
                        Text(url.host ?? preview.url).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(.primary)
                .padding(10)
                .background(
                    ChahuaTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10)
                )
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(ChahuaTheme.accent).frame(width: 3)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

private struct DraftLinkPreviewThumbnail: View {
    let source: String
    @State private var decodedImage: CGImage?

    var body: some View {
        Group {
            if source.hasPrefix("data:") {
                if let decodedImage {
                    Image(decorative: decodedImage, scale: 1).resizable().scaledToFill()
                } else {
                    Color.clear
                }
            } else {
                // This is the server-owned cache URL, never a destination metadata request.
                RemoteImageView(url: URL(string: source))
            }
        }
        .task(id: source) {
            decodedImage = nil
            guard source.hasPrefix("data:image/"), let comma = source.firstIndex(of: ","),
                source[..<comma].hasSuffix(";base64"),
                let data = Data(base64Encoded: String(source[source.index(after: comma)...])),
                let imageSource = CGImageSourceCreateWithData(data as CFData, nil)
            else { return }
            decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
        }
    }
}

/// The shell asks the active transient editor before changing conversations. Local
/// sheets do not ask, and the ordinary persisted draft is never part of this lease.
@MainActor
final class MessageEditExitCoordinator: ObservableObject {
    let exitGuard = FormExitGuard()
    private var owner: UUID?
    private var onLeave: (() -> Void)?

    func register(owner: UUID, onLeave: @escaping () -> Void) {
        self.owner = owner
        self.onLeave = onLeave
    }

    func unregister(owner: UUID) {
        guard self.owner == owner else { return }
        invalidate()
    }

    func requestExit(_ action: @escaping () -> Void, onCancel: (() -> Void)? = nil) {
        exitGuard.requestExit {
            let leave = self.onLeave
            self.invalidate()
            leave?()
            action()
        } onCancel: {
            onCancel?()
        }
    }

    func invalidate() {
        owner = nil
        onLeave = nil
        exitGuard.invalidate()
    }
}

private struct MessageEditExitCoordinatorKey: EnvironmentKey {
    nonisolated static let defaultValue: MessageEditExitCoordinator? = nil
}

extension EnvironmentValues {
    var messageEditExitCoordinator: MessageEditExitCoordinator? {
        get { self[MessageEditExitCoordinatorKey.self] }
        set { self[MessageEditExitCoordinatorKey.self] = newValue }
    }
}
