import AVFoundation
import ChahuaAPI
import Combine
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ShareExtensionModel: ObservableObject {
    enum State: Equatable {
        case preparing
        case ready
        case missingAuthentication
        case failed
        case sending
        case sent
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var destinations: [ShareDestination] = []
    @Published private(set) var selectedDestination: ShareDestination?
    @Published var caption = ""
    @Published private(set) var media: [ShareMedia] = []
    @Published private(set) var contentSummary = "Preparing shared content…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var isUploading = false
    @Published private(set) var compressionEnabled = true
    @Published private(set) var isPreparingContent = false
    @Published private(set) var isLoadingDestinations = false
    @Published private(set) var payloadErrorMessage: String?
    @Published private(set) var destinationErrorMessage: String?
    @Published private(set) var isCheckingPermission = false
    @Published private(set) var destinationPermissionMessage: String?
    @Published private(set) var canWriteToDestination = false

    var hasImages: Bool {
        media.contains { $0.contentType.lowercased().hasPrefix("image/") }
    }

    var canEditContent: Bool {
        state == .ready && lockedDestination == nil && pendingMessageRequest == nil
    }

    var canSend: Bool {
        state == .ready && contentAcquired && !isPreparingContent && payloadErrorMessage == nil
            && selectedDestination != nil
            && !isCheckingPermission && canWriteToDestination
            && (media.isEmpty
                ? !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true)
    }

    var canChangeDestination: Bool {
        canEditContent
    }

    private let providers: [NSItemProvider]
    private var temporaryFiles = ShareTemporaryFiles()
    private var api: (any ChahuaAPIClient)?
    private var contentAcquired = false
    private var attachmentIDs: [String] = []
    private var pendingMessageRequest: ShareMessageRequest?
    private var sendID = UUID().uuidString
    private var generation = 0
    private var sendTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var sessionToken: String?
    private var lockedDestination: ShareDestination?
    private var loadTask: Task<Void, Never>?
    private var permissionID = UUID()
    private let startupStartedAt = ContinuousClock.now
    private var measuredMilestones: Set<String> = []
    private static let startupLogger = Logger(
        subsystem: "app.chahua.chat.share", category: "Startup")

    init(extensionItems: [NSExtensionItem]) {
        providers = extensionItems.flatMap { $0.attachments ?? [] }
    }

    func load() async {
        loadTask?.cancel()
        preparationTask?.cancel()
        permissionTask?.cancel()
        permissionID = UUID()
        canWriteToDestination = false
        destinationPermissionMessage = nil
        isCheckingPermission = false
        selectedDestination = nil
        destinations = []
        generation += 1
        let currentGeneration = generation
        state = .preparing
        errorMessage = nil
        payloadErrorMessage = nil
        destinationErrorMessage = nil
        isPreparingContent = !contentAcquired
        isLoadingDestinations = true
        let task = Task { await self.performLoad(generation: currentGeneration) }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == currentGeneration else { return }
                self?.cancel()
            }
        }
    }

    private func performLoad(generation currentGeneration: Int) async {
        defer {
            if generation == currentGeneration { loadTask = nil }
        }
        do {
            let token = try SharedSessionCredentials.loadToken()?.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard let token, !token.isEmpty else {
                state = .missingAuthentication
                contentSummary = "Sign in to Chahua to share this content."
                return
            }
            let api = ChahuaClient(
                configuration: try ShareExtensionConfiguration.apiConfiguration, token: token)
            if let sessionToken, sessionToken != token {
                guard lockedDestination == nil else {
                    throw ShareExtensionError.accountChangedAfterSend
                }
                attachmentIDs = []
                pendingMessageRequest = nil
                sendID = UUID().uuidString
            }
            self.sessionToken = token
            self.api = api

            // Normal requests validate the session. Do not add a /me startup round trip.
            state = .ready
            async let payload: Void = preparePayload(using: api, generation: currentGeneration)
            async let destinations: Void = loadDestinations(
                using: api, generation: currentGeneration)
            _ = await (payload, destinations)
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration else { return }
            present(error: error, whileLoading: true)
        }
    }

    private func preparePayload(using api: any ChahuaAPIClient, generation currentGeneration: Int)
        async
    {
        do {
            if !contentAcquired {
                try await acquireContent(generation: currentGeneration)
            }
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            isPreparingContent = false
            recordStartupMilestone("payload_ready")
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration else { return }
            isPreparingContent = false
            if Self.isAuthenticationError(error) {
                present(error: error, whileLoading: true)
            } else {
                payloadErrorMessage = Self.message(for: error)
            }
        }
    }

    // The extension cannot observe the system share-sheet tap. This clock starts at model
    // creation, the first extension entry point; use a system trace for pre-entry launch time.
    func recordStartupMilestone(_ milestone: String) {
        guard measuredMilestones.insert(milestone).inserted else { return }
        let elapsed = startupStartedAt.duration(to: .now)
        let milliseconds =
            Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        Self.startupLogger.notice(
            "\(milestone, privacy: .public) elapsed_ms=\(milliseconds, privacy: .public)")
    }

    func retry() {
        guard state != .sending, state != .sent else { return }
        if state == .ready, errorMessage != nil {
            send()
        } else {
            Task { await load() }
        }
    }

    func selectDestination(_ destination: ShareDestination) {
        guard let api, canChangeDestination, destinations.contains(destination) else { return }
        selectedDestination = destination
        canWriteToDestination = false
        destinationPermissionMessage = nil
        isCheckingPermission = true
        permissionTask?.cancel()
        let id = UUID()
        permissionID = id
        permissionTask = Task { [weak self] in
            await self?.checkPermission(for: destination, using: api, permissionID: id)
        }
    }

    func retryPermission() {
        guard let selectedDestination else { return }
        selectDestination(selectedDestination)
    }

    func retryPreparation() {
        guard let api, state == .ready, !isPreparingContent else { return }
        isPreparingContent = true
        payloadErrorMessage = nil
        let currentGeneration = generation
        preparationTask = Task {
            await self.preparePayload(using: api, generation: currentGeneration)
        }
    }

    private func checkPermission(
        for destination: ShareDestination, using api: any ChahuaAPIClient, permissionID: UUID
    ) async {
        do {
            let info = try await api.groupInfo(chatID: destination.chatID)
            guard info.id == destination.chatID else { throw APIError.unexpectedResponse }
            var canWrite = info.myRole != nil
            if info.kind == .dm {
                canWrite = false
                if let peer = info.peer {
                    let relationship = try await api.friendRelationship(peerUID: peer.uid)
                    guard relationship.peerUid == peer.uid else {
                        throw APIError.unexpectedResponse
                    }
                    canWrite = info.myRole != nil && relationship.canDm
                }
            } else if info.myRole != .admin {
                // The subscribed-thread page establishes an existing thread. Main messages
                // and replies still have different speaking rules.
                canWrite =
                    canWrite
                    && (destination.threadID.isEmpty
                        ? info.effectiveSpeakingMode?.allowsMainMessages == true
                        : info.effectiveSpeakingMode?.allowsThreadReplies == true)
            }
            try Task.checkCancellation()
            guard self.permissionID == permissionID else { return }
            canWriteToDestination = canWrite
            isCheckingPermission = false
            destinationPermissionMessage = canWrite ? nil : "You can’t send to this destination."
        } catch is CancellationError {
            return
        } catch {
            guard self.permissionID == permissionID else { return }
            isCheckingPermission = false
            if Self.isAuthenticationError(error) {
                present(error: error, whileLoading: false)
            } else {
                destinationPermissionMessage = Self.message(for: error)
            }
        }
    }

    func setCompressionEnabled(_ enabled: Bool) {
        guard canEditContent, enabled != compressionEnabled else { return }
        compressionEnabled = enabled
        attachmentIDs = []
        // Keep acquired originals for either compression setting; upload only on Send.
    }

    func send() {
        guard let api, let destination = lockedDestination ?? selectedDestination, canSend else {
            return
        }
        lockedDestination = destination
        sendTask?.cancel()
        state = .sending
        errorMessage = nil
        sendTask = Task { [weak self] in
            await self?.performSend(using: api, destination: destination)
        }
    }

    private func performSend(using api: any ChahuaAPIClient, destination: ShareDestination) async {
        let currentGeneration = generation
        do {
            let request: ShareMessageRequest
            if let pendingMessageRequest {
                request = pendingMessageRequest
            } else {
                try await uploadMedia(using: api, generation: currentGeneration)
                try Task.checkCancellation()
                guard generation == currentGeneration else { return }
                request = ShareMessageRequest(
                    destination: destination,
                    body: CreateMessageBody(
                        messageType: .text, clientGeneratedId: sendID,
                        message: Self.message(from: caption), attachmentIds: attachmentIDs))
                // Freeze the exact request only after upload succeeds. A retry after a lost
                // response keeps the same body and idempotency identifier.
                pendingMessageRequest = request
            }
            switch request.destination.kind {
            case .chat:
                _ = try await api.sendMessage(
                    chatID: request.destination.chatID, body: request.body)
            case .thread(let threadID):
                _ = try await api.sendThreadMessage(
                    chatID: request.destination.chatID, threadID: threadID, body: request.body)
            }
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            state = .sent
            contentSummary = "Sent to \(request.destination.title)."
            errorMessage = nil
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            state = .ready
            if pendingMessageRequest == nil { lockedDestination = nil }
        } catch {
            guard generation == currentGeneration else { return }
            state = .ready
            if pendingMessageRequest == nil { lockedDestination = nil }
            if Self.isAuthenticationError(error) {
                present(error: error, whileLoading: false)
            } else {
                errorMessage = Self.message(for: error)
            }
        }
    }

    func cancel() {
        generation += 1
        sendTask?.cancel()
        permissionTask?.cancel()
        preparationTask?.cancel()
        permissionID = UUID()
        loadTask?.cancel()
        loadTask = nil
        isUploading = false
        sendTask = nil
        permissionTask = nil
        preparationTask = nil
        temporaryFiles.removeAll()
    }

    func completeAfterConfirmation() {
        temporaryFiles.removeAll()
    }

    deinit {
        temporaryFiles.removeAll()
    }

    private func acquireContent(generation currentGeneration: Int) async throws {
        // Separate attempts own separate directories. A late provider callback from a cancelled
        // attempt must not replace the new draft or delete its files.
        let files = ShareTemporaryFiles()
        do {
            let result = try await ShareContentAcquirer.acquire(
                providers: providers, directory: files.directory, maximumFileSize: .max)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            if result.draft.isEmpty {
                throw ShareExtensionError.noSupportedContent(result.failures)
            }
            guard result.failures.isEmpty else {
                throw ShareExtensionError.incompleteAcquisition(result.failures)
            }
            temporaryFiles.removeAll()
            temporaryFiles = files
            let draft = result.draft
            media = draft.media
            // Preserve caption edits made while cloud-backed media was loading.
            if let sharedText = draft.messageText {
                caption = caption.isEmpty ? sharedText : sharedText + "\n" + caption
            }
            contentAcquired = true
            contentSummary = draft.summary
        } catch {
            files.removeAll()
            throw error
        }
    }

    private func uploadMedia(using api: any ChahuaAPIClient, generation currentGeneration: Int)
        async throws
    {
        guard !media.isEmpty, attachmentIDs.count != media.count else { return }
        isUploading = true
        defer { isUploading = false }
        let maximumFileSize = try await api.attachmentConfig().maxFileSizeBytes
        for index in attachmentIDs.count..<media.count {
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            let item = try await ShareContentAcquirer.prepare(
                media[index], compressionEnabled: compressionEnabled)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            guard item.byteCount <= maximumFileSize else {
                throw ShareExtensionError.fileTooLarge(maximumFileSize)
            }
            let allocation = try await api.requestAttachmentUpload(
                fileName: item.fileName, contentType: item.contentType, purpose: .media,
                size: item.byteCount, width: item.width, height: item.height, order: index)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            try await ShareAttachmentUploader.upload(file: item.url, allocation: allocation)
            try Task.checkCancellation()
            guard generation == currentGeneration else { throw CancellationError() }
            attachmentIDs.append(allocation.attachmentId)
        }
    }

    private static func message(from caption: String) -> String? {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func present(error: Error, whileLoading: Bool) {
        if Self.isAuthenticationError(error) {
            state = .missingAuthentication
            errorMessage =
                "Your Chahua session has expired. Sign in to Chahua, then retry this share."
            return
        }
        state = .failed
        errorMessage = Self.message(for: error)
        if whileLoading { contentSummary = "Your shared items are still available to retry." }
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        guard let error = error as? APIError else { return false }
        return switch error {
        case .invalidToken, .unauthorized: true
        default: false
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ShareExtensionError { return error.localizedDescription }
        if let error = error as? APIError {
            switch error {
            case .transport:
                return "Chahua couldn’t be reached. Check your connection and retry."
            case .http(let status, _), .invalidResponse(let status):
                return "Chahua couldn’t complete the request (HTTP \(status)). Retry this share."
            default:
                return "Chahua couldn’t complete the request. Retry this share."
            }
        }
        return "Chahua couldn’t complete the request. Retry this share."
    }

    private func loadDestinations(using api: any ChahuaAPIClient, generation currentGeneration: Int)
        async
    {
        // One recent page from each list. Do not walk cursors or preflight every chat.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                do {
                    let page = try await api.listChats(query: .init(limit: 20, archived: false))
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration, self.state == .ready else { return }
                    self.destinations.append(
                        contentsOf: page.chats.map { chat in
                            let title =
                                chat.kind == .dm
                                ? chat.peer?.username ?? chat.name ?? "Chat" : chat.name ?? "Chat"
                            return .chat(
                                chatID: chat.id, title: title,
                                subtitle: chat.lastMessage.map {
                                    Self.previewText($0, fallback: "Message")
                                },
                                activityDate: chat.lastMessageAt ?? .distantPast,
                                avatarURL: (chat.kind == .dm ? chat.peer?.avatarUrl : chat.avatar)
                                    .flatMap(URL.init(string:)),
                                avatarName: title)
                        })
                    self.destinations.sort(by: Self.destinationOrder)
                } catch {
                    self.presentDestinationError(error, generation: currentGeneration)
                }
            }
            group.addTask { @MainActor in
                do {
                    let page = try await api.listThreads(query: .init(limit: 20, archived: false))
                    try Task.checkCancellation()
                    guard self.generation == currentGeneration, self.state == .ready else { return }
                    self.destinations.append(
                        contentsOf: page.threads.map { thread in
                            let root = thread.threadRootMessage
                            let rootName = root.sender.name?.trimmingCharacters(
                                in: .whitespacesAndNewlines)
                            let badge: ShareDestination.AvatarBadge? =
                                thread.chatKind == .dm
                                ? .thread
                                : rootName?.isEmpty == false
                                    ? .person(
                                        url: root.sender.avatarUrl.flatMap(URL.init(string:)),
                                        name: rootName!)
                                    : nil
                            let title =
                                thread.chatKind == .dm
                                ? thread.peer?.username ?? thread.chatName : thread.chatName
                            return .thread(
                                chatID: thread.chatId, threadID: root.id.description,
                                title: Self.previewText(root, fallback: "Message"),
                                subtitle: Self.previewText(
                                    thread.lastReply ?? root, fallback: "Message"),
                                activityDate: thread.lastReplyAt,
                                avatarURL: (thread.chatKind == .dm
                                    ? thread.peer?.avatarUrl : thread.chatAvatar)
                                    .flatMap(URL.init(string:)),
                                avatarName: title, avatarBadge: badge)
                        })
                    self.destinations.sort(by: Self.destinationOrder)
                } catch {
                    self.presentDestinationError(error, generation: currentGeneration)
                }
            }
        }
        guard generation == currentGeneration else { return }
        isLoadingDestinations = false
    }

    private func presentDestinationError(_ error: Error, generation currentGeneration: Int) {
        guard !(error is CancellationError), generation == currentGeneration else { return }
        if Self.isAuthenticationError(error) {
            present(error: error, whileLoading: true)
        } else {
            destinationErrorMessage = Self.message(for: error)
        }
    }

    private static func destinationOrder(_ lhs: ShareDestination, _ rhs: ShareDestination) -> Bool {
        if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
        if lhs.chatID != rhs.chatID { return lhs.chatID < rhs.chatID }
        return lhs.threadID < rhs.threadID
    }
    private static func previewText(_ preview: MessagePreview, fallback: String = "") -> String {
        let rendered = MessagePreviewRenderer.render(
            preview,
            labels: .init(
                attachment: "[Attachment]", deleted: "[Deleted]", image: "[Image]",
                invite: "[Invite]", sticker: "[Sticker]", video: "[Video]",
                voiceMessage: "[Voice message]"))
        return rendered.isEmpty ? fallback : rendered
    }

}

struct ShareDestination: Identifiable, Hashable {
    enum Kind: Hashable {
        case chat
        case thread(String)
    }

    enum AvatarBadge: Hashable {
        case person(url: URL?, name: String)
        case thread
    }

    let chatID: String
    let title: String
    let subtitle: String?
    let kind: Kind
    let activityDate: Date
    let avatarURL: URL?
    let avatarName: String
    let avatarBadge: AvatarBadge?

    var id: String {
        switch kind {
        case .chat: "chat:\(chatID)"
        case .thread(let id): "thread:\(chatID):\(id)"
        }
    }

    var threadID: String {
        if case .thread(let id) = kind { return id }
        return ""
    }

    static func chat(
        chatID: String, title: String, subtitle: String?, activityDate: Date, avatarURL: URL?,
        avatarName: String
    ) -> Self {
        Self(
            chatID: chatID, title: title, subtitle: subtitle, kind: .chat,
            activityDate: activityDate, avatarURL: avatarURL, avatarName: avatarName,
            avatarBadge: nil)
    }

    static func thread(
        chatID: String, threadID: String, title: String, subtitle: String?, activityDate: Date,
        avatarURL: URL?, avatarName: String, avatarBadge: AvatarBadge?
    ) -> Self {
        Self(
            chatID: chatID, title: title, subtitle: subtitle, kind: .thread(threadID),
            activityDate: activityDate, avatarURL: avatarURL, avatarName: avatarName,
            avatarBadge: avatarBadge)
    }
}

private struct ShareMessageRequest {
    let destination: ShareDestination
    let body: CreateMessageBody
}

nonisolated private struct ShareDraft: Sendable {
    var text: [String] = []
    var urls: [URL] = []
    var media: [ShareMedia] = []

    var isEmpty: Bool { text.isEmpty && urls.isEmpty && media.isEmpty }

    var messageText: String? {
        let lines = text + urls.map(\.absoluteString)
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    var summary: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append("\(text.count) text item\(text.count == 1 ? "" : "s")") }
        if !urls.isEmpty { parts.append("\(urls.count) link\(urls.count == 1 ? "" : "s")") }
        if !media.isEmpty {
            parts.append("\(media.count) media item\(media.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No shareable content was found." : parts.joined(separator: ", ")
    }
}

nonisolated struct ShareMedia: Identifiable, Sendable {
    let url: URL
    let fileName: String
    let contentType: String
    let byteCount: Int64
    let width: Int
    let height: Int

    var id: URL { url }
}

nonisolated private struct ShareAcquisitionResult: Sendable {
    let draft: ShareDraft
    let failures: [String]
}

nonisolated private enum ShareContentAcquirer {
    static func prepare(_ media: ShareMedia, compressionEnabled: Bool) async throws -> ShareMedia {
        guard compressionEnabled, media.contentType.lowercased().hasPrefix("image/") else {
            return media
        }
        let worker = Task.detached(priority: .utility) {
            try autoreleasepool {
                try Task.checkCancellation()
                guard
                    let source = CGImageSourceCreateWithURL(
                        media.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                else { throw ShareExtensionError.unsupportedMedia }
                guard
                    let output = try StillImagePreparation.prepare(
                        source: source, originalByteCount: media.byteCount,
                        directory: media.url.deletingLastPathComponent())
                else { return media }
                let stem = URL(fileURLWithPath: media.fileName)
                    .deletingPathExtension().lastPathComponent
                return ShareMedia(
                    url: output.url, fileName: "\(stem).\(output.extensionName)",
                    contentType: output.mimeType, byteCount: output.byteCount,
                    width: output.width, height: output.height)
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func acquire(providers: [NSItemProvider], directory: URL, maximumFileSize: Int64)
        async throws
        -> ShareAcquisitionResult
    {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var draft = ShareDraft()
        var failures: [String] = []
        for provider in providers {
            do {
                if let media = try await loadMedia(
                    from: provider, directory: directory, maximumFileSize: maximumFileSize)
                {
                    draft.media.append(media)
                } else if let url = try await loadWebURL(from: provider) {
                    draft.urls.append(url)
                } else if let text = try await loadText(from: provider) {
                    draft.text.append(text)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        return ShareAcquisitionResult(draft: draft, failures: failures)
    }

    private static func loadMedia(
        from provider: NSItemProvider, directory: URL, maximumFileSize: Int64
    ) async throws -> ShareMedia? {
        guard
            let type = provider.registeredTypeIdentifiers.lazy.compactMap({ UTType($0) }).first(
                where: {
                    $0.conforms(to: .image) || $0.conforms(to: .movie)
                })
        else { return nil }
        // Retain provider originals here; the server limit is checked after preparation on Send.
        let copyLimit = type.conforms(to: .image) ? Int64.max : maximumFileSize
        let copied = try await copyFileRepresentation(
            from: provider, type: type, directory: directory, maximumFileSize: copyLimit)
        do {
            return try await mediaMetadata(for: copied)
        } catch {
            try? FileManager.default.removeItem(at: copied)
            throw error
        }
    }

    private static func loadWebURL(from provider: NSItemProvider) async throws -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        let item = try await item(from: provider, type: .url)
        let url: URL?
        if let value = item as? URL {
            url = value
        } else if let value = item as? NSURL {
            url = value as URL
        } else if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
            url = nil
        }
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme)
        else {
            return nil
        }
        return url
    }

    private static func loadText(from provider: NSItemProvider) async throws -> String? {
        let type: UTType
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            type = .plainText
        } else if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            type = .text
        } else {
            return nil
        }
        let item = try await item(from: provider, type: type)
        // NSString item providers may return their UTF-8 data representation.
        let text =
            (item as? String) ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        guard let text else { throw ShareExtensionError.unavailable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func item(from provider: NSItemProvider, type: UTType) async throws
        -> NSSecureCoding
    {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let item {
                    continuation.resume(returning: item)
                } else {
                    continuation.resume(throwing: ShareExtensionError.unavailable)
                }
            }
        }
    }
    /// NSItemProvider revokes a file-representation URL when this callback returns.
    /// Copy synchronously here instead of resuming with the ephemeral URL.
    private static func copyFileRepresentation(
        from provider: NSItemProvider, type: UTType, directory: URL, maximumFileSize: Int64
    ) async throws -> URL {
        let suggestedName = provider.suggestedName
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, error in
                do {
                    guard let source else { throw error ?? ShareExtensionError.unavailable }
                    continuation.resume(
                        returning: try copyProviderFile(
                            from: source, to: directory, maximumFileSize: maximumFileSize,
                            suggestedName: suggestedName,
                            fileExtension: type.preferredFilenameExtension))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func copyProviderFile(
        from source: URL, to directory: URL, maximumFileSize: Int64, suggestedName: String?,
        fileExtension: String?
    ) throws -> URL {
        guard !Task.isCancelled else { throw CancellationError() }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ShareExtensionError.unsupportedMedia }
        if let size = values.fileSize, Int64(size) > maximumFileSize {
            throw ShareExtensionError.fileTooLarge(maximumFileSize)
        }
        var name = sanitizedFileName(suggestedName ?? source.lastPathComponent)
        // Hosts often supply a display name without a suffix. AVFoundation and
        // upload MIME detection still need the representation's media extension.
        if URL(fileURLWithPath: name).pathExtension.isEmpty {
            let suffix = fileExtension ?? source.pathExtension
            if !suffix.isEmpty { name += "." + suffix }
        }
        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(name)")
        guard
            FileManager.default.createFile(
                atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var total: Int64 = 0
        do {
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                guard !Task.isCancelled else { throw CancellationError() }
                total += Int64(data.count)
                guard total <= maximumFileSize else {
                    throw ShareExtensionError.fileTooLarge(maximumFileSize)
                }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private static func sanitizedFileName(_ candidate: String) -> String {
        let name = URL(fileURLWithPath: candidate).lastPathComponent
        return name.isEmpty ? "shared-media" : name.replacingOccurrences(of: "/", with: "-")
    }

    private static func mediaMetadata(for url: URL) async throws -> ShareMedia {
        if let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            let identifier = CGImageSourceGetType(source), let type = UTType(identifier as String),
            type.conforms(to: .image), let contentType = type.preferredMIMEType,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0
        {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapped = (5...8).contains(orientation)
            return try media(
                url: url, contentType: contentType, width: swapped ? height : width,
                height: swapped ? width : height)
        }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration).seconds
        guard playable, duration.isFinite, duration > 0,
            let track = try await asset.loadTracks(withMediaType: .video).first
        else { throw ShareExtensionError.unsupportedMedia }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard bounds.width >= 1, bounds.height >= 1, bounds.width.isFinite, bounds.height.isFinite
        else {
            throw ShareExtensionError.unsupportedMedia
        }
        let contentType =
            UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "video/mp4"
        return try media(
            url: url, contentType: contentType, width: Int(bounds.width.rounded()),
            height: Int(bounds.height.rounded()))
    }

    private static func media(url: URL, contentType: String, width: Int, height: Int) throws
        -> ShareMedia
    {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else {
            throw ShareExtensionError.unsupportedMedia
        }
        return ShareMedia(
            url: url, fileName: url.lastPathComponent, contentType: contentType,
            byteCount: Int64(size),
            width: width, height: height)
    }
}

private enum ShareAttachmentUploader {
    static func upload(file: URL, allocation: OutgoingUploadAllocation) async throws {
        let url = allocation.uploadURL
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil,
            !allocation.headers.keys.contains(where: {
                ["authorization", "proxy-authorization", "cookie"].contains($0.lowercased())
            })
        else { throw ShareExtensionError.unsafeUpload }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in allocation.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = ShareUploadDelegate()
        let (_, response) = try await session.upload(
            for: request, fromFile: file, delegate: delegate)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw ShareExtensionError.invalidUpload
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ShareExtensionError.uploadStatus(response.statusCode)
        }
    }
}

private final class ShareUploadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

nonisolated private final class ShareTemporaryFiles: Sendable {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "chahua-share-\(UUID().uuidString)", isDirectory: true)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum ShareExtensionConfiguration {
    static var apiConfiguration: ChahuaConfiguration {
        get throws {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String,
                let baseURL = URL(string: raw), let scheme = baseURL.scheme?.lowercased(),
                ["http", "https"].contains(scheme), baseURL.host != nil
            else { throw ShareExtensionError.invalidConfiguration }
            #if os(iOS)
                let platform = "ios"
            #elseif os(macOS)
                let platform = "macos"
            #else
                #error("Unsupported Chahua platform")
            #endif
            let version =
                (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
                ?? "0"
            let build =
                (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
            return ChahuaConfiguration(
                baseURL: baseURL, appVersion: "\(platform)-\(version)-\(build)")
        }
    }
}

nonisolated private enum ShareExtensionError: LocalizedError {
    case unavailable
    case invalidConfiguration
    case unsupportedMedia
    case fileTooLarge(Int64)
    case noSupportedContent([String])
    case incompleteAcquisition([String])
    case accountChangedAfterSend
    case unsafeUpload
    case invalidUpload
    case uploadStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "This shared item couldn’t be read. Try sharing it again."
        case .invalidConfiguration: "Chahua isn’t configured for sharing on this device."
        case .unsupportedMedia: "Only images and videos can be sent as media."
        case .fileTooLarge(let limit):
            "A shared file exceeds Chahua’s \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)) limit."
        case .noSupportedContent(let failures):
            failures.first ?? "This share does not contain text, web links, images, or videos."
        case .incompleteAcquisition(let failures):
            "Every shared item must be available before sending. \(failures.first ?? "Retry this share.")"
        case .accountChangedAfterSend:
            "This share was started by a different Chahua account. Cancel it and share again."
        case .unsafeUpload: "Chahua rejected an unsafe media upload instruction."
        case .invalidUpload: "The media upload returned an invalid response."
        case .uploadStatus(let status): "The media upload failed (HTTP \(status))."
        }
    }
}
