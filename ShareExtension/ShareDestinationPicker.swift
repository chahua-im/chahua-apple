import Foundation
import SwiftUI

struct ShareExtensionRootView: View {
    @ObservedObject var model: ShareExtensionModel
    let onCancel: () -> Void
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isCaptionFocused: Bool
    @State private var showsSearch = false
    @State private var searchText = ""
    @ScaledMetric(relativeTo: .body) private var previewHeight: CGFloat = 152

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                    .onTapGesture(perform: dismissInput)

                VStack(spacing: 12) {
                    mainCard
                        .frame(height: mainCardHeight(in: geometry.size.height))

                    if model.state != .ready && model.state != .sent {
                        cancelCard
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .task {
            guard model.state == .preparing else { return }
            await model.load()
        }
        .task(id: model.state) {
            guard model.state == .sent else { return }
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, model.state == .sent else { return }
            onComplete()
        }
    }

    private var mainCard: some View {
        Group {
            switch model.state {
            case .preparing:
                loading
            case .missingAuthentication:
                authenticationRequired
            case .failed:
                failure
            case .ready:
                shareForm
            case .sending:
                sendingConfirmation
            case .sent:
                sentConfirmation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
                .onTapGesture(perform: dismissInput)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

            Text("Share with")
                .font(.title3.weight(.semibold))
                .onTapGesture(perform: dismissInput)

            Spacer(minLength: 0)

            Button {
                isCaptionFocused = false
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    showsSearch.toggle()
                    if !showsSearch { searchText = "" }
                    if !showsSearch { isSearchFocused = false }
                }
                if showsSearch {
                    isSearchFocused = true
                }
            } label: {
                Image(systemName: showsSearch ? "xmark.circle.fill" : "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(!model.canChangeDestination)
            .accessibilityLabel(showsSearch ? "Hide search" : "Search destinations")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var shareForm: some View {
        VStack(spacing: 0) {
            header

            if isCaptionFocused {
                ScrollView {
                    HStack(spacing: 12) {
                        ShareSharedContentPreview(media: model.media, message: model.caption)
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityIdentifier("share.compactPreview")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                model.media.isEmpty
                                    ? "Message"
                                    : model.media.count == 1
                                        ? "1 media item"
                                        : "\(model.media.count) media items"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(selectedDestinationTitle)
                                .font(.headline)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Button(model.selectedDestination == nil ? "Choose" : "Change") {
                            dismissInput()
                        }
                        .disabled(!model.canChangeDestination)
                    }
                    .padding(16)
                    .contentShape(Rectangle())
                }
                .scrollBounceBehavior(.basedOnSize)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { dismissInput() })
            } else {
                ShareSharedContentPreview(media: model.media, message: model.caption)
                    .frame(height: isSearchFocused ? 72 : previewHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .simultaneousGesture(TapGesture().onEnded { dismissInput() })

                destinationPicker
                    .frame(maxHeight: .infinity)
            }

            // The composer stays outside scrolling content and retains its identity on focus changes.
            captionEditor
            transferStatus
            sendButton
        }
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsSearch {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search chats and threads", text: $searchText)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .submitLabel(.done)
                        .accessibilityLabel("Search chats and threads")
                        .onSubmit { isSearchFocused = false }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 16)
            }

            Text("Recent chats and threads")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .onTapGesture(perform: dismissInput)

            if matchingDestinations.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 20)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 64, maximum: 96), spacing: 12)
                        ],
                        alignment: .center,
                        spacing: 14
                    ) {
                        ForEach(matchingDestinations) { destination in
                            destinationTile(destination)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    /// Placeholder-only field with an inset surface; its accessibility label remains explicit.
    private var captionEditor: some View {
        TextField(
            model.media.isEmpty ? "Message" : "Add a caption…", text: $model.caption,
            axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...3)
        .focused($isCaptionFocused)
        .accessibilityIdentifier("share.caption")
        .disabled(!model.canEditContent)
        .accessibilityLabel(model.media.isEmpty ? "Message" : "Caption")
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            Color.secondary.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var transferStatus: some View {
        if model.isUploading {
            HStack(spacing: 10) {
                ProgressView(value: model.uploadProgress)
                    .frame(maxWidth: .infinity)
                Text("Uploading media…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        } else if let uploadError = model.uploadErrorMessage {
            retryStatus(uploadError, retryTitle: "Retry upload", action: model.retryUpload)
        } else if let error = model.errorMessage {
            retryStatus(error, retryTitle: "Retry Send", action: model.retry)
        }
    }

    private var sendButton: some View {
        Button {
            dismissInput()
            model.send()
        } label: {
            Label("Send", systemImage: "paperplane.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .disabled(!model.canSend)
        .accessibilityIdentifier("share.send")
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityHint(
            model.canSend
                ? "Sends to \(selectedDestinationTitle)"
                : "Choose a ready destination before sending")
    }

    private var loading: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Preparing your share…")
                .font(.headline)
            Text(model.contentSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var authenticationRequired: some View {
        unavailableState(
            title: "Sign in to Chahua",
            systemImage: "person.crop.circle.badge.exclamationmark",
            description: model.errorMessage ?? model.contentSummary,
            actionTitle: "Retry",
            action: model.retry
        )
    }

    private var failure: some View {
        unavailableState(
            title: isEmptyDestinationState ? "No destinations available" : "Couldn’t prepare share",
            systemImage: isEmptyDestinationState
                ? "bubble.left.and.bubble.right" : "exclamationmark.triangle",
            description: model.errorMessage ?? model.contentSummary,
            actionTitle: "Retry",
            action: model.retry
        )
    }

    private var sendingConfirmation: some View {
        VStack(spacing: 16) {
            ShareSendingRing(reduceMotion: reduceMotion)
                .frame(width: 64, height: 64)
            Text("Sending…")
                .font(.title3.weight(.semibold))
            Text("Your share is on its way to \(selectedDestinationTitle).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending to \(selectedDestinationTitle)")
    }

    private var sentConfirmation: some View {
        VStack(spacing: 16) {
            ShareSentCheckmark(reduceMotion: reduceMotion)
                .frame(width: 64, height: 64)
            Text("Sent")
                .font(.title3.weight(.semibold))
            Text("Sent to \(selectedDestinationTitle)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sent to \(selectedDestinationTitle)")
    }

    private var cancelCard: some View {
        Button("Cancel", action: onCancel)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                .regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .accessibilityHint("Cancels this share")
    }

    private var matchingDestinations: [ShareDestination] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.destinations }
        return model.destinations.filter { destination in
            destination.title.localizedCaseInsensitiveContains(query)
                || (destination.subtitle?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var isEmptyDestinationState: Bool {
        model.errorMessage?.contains("don’t have a chat or thread") == true
    }

    private var selectedDestinationTitle: String {
        guard let destination = model.selectedDestination else { return "Choose a destination" }
        return destination.title
    }

    private func destinationTile(_ destination: ShareDestination) -> some View {
        let isSelected = model.selectedDestination?.id == destination.id
        return Button {
            model.selectDestination(destination)
            dismissInput()
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ShareDestinationAvatar(destination: destination, diameter: 52)
                        .padding(4)
                        .overlay {
                            Circle()
                                .stroke(
                                    isSelected ? Color.accentColor : Color.clear,
                                    lineWidth: 3
                                )
                        }

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.accentColor, in: Circle())
                            .overlay {
                                Circle().stroke(.background, lineWidth: 2)
                            }
                            .offset(x: 2, y: 2)
                            .accessibilityHidden(true)
                    }
                }

                Text(destination.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

            }
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canChangeDestination)
        .opacity(model.canChangeDestination || isSelected ? 1 : 0.55)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            destination.subtitle?.isEmpty == false
                ? "\(destination.title), \(destination.subtitle!)"
                : destination.title
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(
            isSelected
                ? "Selected destination"
                : model.canChangeDestination
                    ? "Select destination" : "Destination is locked while sending"
        )
    }

    private func retryStatus(_ message: String, retryTitle: String, action: @escaping () -> Void)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(retryTitle, action: action)
                .font(.footnote.weight(.semibold))
                .disabled(!model.canEditContent && model.errorMessage == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func unavailableState(
        title: String, systemImage: String, description: String, actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
    }

    private func dismissInput() {
        isCaptionFocused = false
        isSearchFocused = false
    }

    private func mainCardHeight(in availableHeight: CGFloat) -> CGFloat {
        if model.state == .sending || model.state == .sent {
            return min(210, availableHeight - 80)
        }
        let available = max(0, availableHeight - (model.state == .ready ? 12 : 80))
        if isCaptionFocused { return min(300, available) }
        return min(720, available)
    }
}

private struct ShareSendingRing: View {
    let reduceMotion: Bool
    @State private var rotation = 0.0

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(
                Color.accentColor,
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
            .onChange(of: reduceMotion) { _, isReduced in
                guard isReduced else { return }
                rotation = 0
            }
            .accessibilityLabel("Sending")
    }
}

private struct ShareSentCheckmark: View {
    let reduceMotion: Bool
    @State private var scale: CGFloat = 0.7

    var body: some View {
        Image(systemName: "checkmark.circle")
            .font(.system(size: 64, weight: .regular))
            .foregroundStyle(Color.accentColor)
            .scaleEffect(scale)
            .onAppear {
                guard !reduceMotion else {
                    scale = 1
                    return
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.58)) {
                    scale = 1
                }
            }
            .accessibilityHidden(true)
    }
}
