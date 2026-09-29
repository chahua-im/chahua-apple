import AVFoundation
import ChahuaAPI
import Combine
import CoreGraphics
import Foundation
import ImageIO
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
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var isUploading = false
    @Published private(set) var uploadErrorMessage: String?

    var canEditContent: Bool {
        state == .ready && lockedDestination == nil && pendingMessageRequest == nil
    }

    var canSend: Bool {
        state == .ready
            && (lockedDestination ?? selectedDestination) != nil
            && !isUploading
            && uploadErrorMessage == nil
            && (media.isEmpty || attachmentIDs.count == media.count)
            && (media.isEmpty
                ? !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : true)
    }

    var canChangeDestination: Bool {
        canEditContent
    }

    private let providers: [NSItemProvider]
    private let temporaryFiles = ShareTemporaryFiles()
    private var api: (any ChahuaAPIClient)?
    private var maximumFileSize: Int64?
    private var draft = ShareDraft()
    private var contentAcquired = false
    private var attachmentIDs: [String] = []
    private var pendingMessageRequest: ShareMessageRequest?
    private var sendID = UUID().uuidString
    private var generation = 0
    private var sendTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    private var uploadID: UUID?
    private var authenticatedUserID: Int32?
    private var lockedDestination: ShareDestination?

    init(extensionItems: [NSExtensionItem]) {
        providers = extensionItems.flatMap { $0.attachments ?? [] }
    }

    func load() async {
        generation += 1
        let currentGeneration = generation
        state = .preparing
        errorMessage = nil
        uploadProgress = 0
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
            let me = try await api.me()
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            if let authenticatedUserID, authenticatedUserID != me.uid {
                guard lockedDestination == nil else {
                    throw ShareExtensionError.accountChangedAfterSend
                }
                uploadTask?.cancel()
                uploadTask = nil
                uploadID = nil
                isUploading = false
                temporaryFiles.removeAll()
                selectedDestination = nil
                destinations = []
                draft = ShareDraft()
                media = []
                caption = ""
                contentAcquired = false
                attachmentIDs = []
                uploadErrorMessage = nil
                pendingMessageRequest = nil
                sendID = UUID().uuidString
            }
            self.authenticatedUserID = me.uid
            self.api = api

            async let loadedDestinations = Self.loadDestinations(using: api)
            let config = try await api.attachmentConfig()
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            maximumFileSize = config.maxFileSizeBytes
            if !contentAcquired {
                try await acquireContent(maximumFileSize: config.maxFileSizeBytes)
            }
            let destinations = try await loadedDestinations
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }
            self.destinations = destinations
            if destinations.isEmpty {
                state = .failed
                contentSummary = "No writable chats or threads are available."
                errorMessage = "You don’t have a chat or thread that can receive this share."
                return
            }
            state = .ready
            ensureMediaUploaded()
        } catch is CancellationError {
            return
        } catch {
            guard generation == currentGeneration else { return }
            present(error: error, whileLoading: true)
        }
    }

    func retry() {
        guard state != .sending, state != .sent else { return }
        if pendingMessageRequest != nil {
            send()
        } else {
            Task { await load() }
        }
    }

    func selectDestination(_ destination: ShareDestination) {
        guard canChangeDestination, destinations.contains(destination) else { return }
        selectedDestination = destination
        ensureMediaUploaded()
    }

    func retryUpload() {
        guard state == .ready, !isUploading, !media.isEmpty, pendingMessageRequest == nil else {
            return
        }
        ensureMediaUploaded()
    }

    func send() {
        guard let api, let destination = lockedDestination ?? selectedDestination, canSend else {
            return
        }
        let request: ShareMessageRequest
        if let pendingMessageRequest {
            request = pendingMessageRequest
        } else {
            request = ShareMessageRequest(
                destination: destination,
                body: CreateMessageBody(
                    messageType: .text,
                    clientGeneratedId: sendID,
                    message: Self.message(from: caption),
                    attachmentIds: attachmentIDs
                ))
            pendingMessageRequest = request
            lockedDestination = destination
        }
        sendTask?.cancel()
        state = .sending
        errorMessage = nil
        sendTask = Task { [weak self] in
            await self?.performSend(using: api, request: request)
        }
    }

    private func performSend(using api: any ChahuaAPIClient, request: ShareMessageRequest) async {
        do {
            switch request.destination.kind {
            case .chat:
                _ = try await api.sendMessage(
                    chatID: request.destination.chatID, body: request.body)
            case .thread(let threadID):
                _ = try await api.sendThreadMessage(
                    chatID: request.destination.chatID, threadID: threadID, body: request.body)
            }
            state = .sent
            contentSummary = "Sent to \(request.destination.title)."
            errorMessage = nil
        } catch is CancellationError {
            state = .ready
        } catch {
            state = .ready
            errorMessage = Self.message(for: error)
        }
    }

    func cancel() {
        generation += 1
        sendTask?.cancel()
        uploadTask?.cancel()
        uploadID = nil
        isUploading = false
        sendTask = nil
        uploadTask = nil
        temporaryFiles.removeAll()
    }

    func completeAfterConfirmation() {
        temporaryFiles.removeAll()
    }

    deinit {
        temporaryFiles.removeAll()
    }

    private func acquireContent(maximumFileSize: Int64) async throws {
        temporaryFiles.removeAll()
        let result = try await ShareContentAcquirer.acquire(
            providers: providers, directory: temporaryFiles.directory,
            maximumFileSize: maximumFileSize)
        if result.draft.isEmpty {
            throw ShareExtensionError.noSupportedContent(result.failures)
        }
        guard result.failures.isEmpty else {
            throw ShareExtensionError.incompleteAcquisition(result.failures)
        }
        draft = result.draft
        media = draft.media
        caption = draft.messageText ?? ""
        contentAcquired = true
        contentSummary = draft.summary
    }

    private func ensureMediaUploaded() {
        guard let api, !media.isEmpty, attachmentIDs.count != media.count, !isUploading else {
            return
        }
        let id = UUID()
        let media = media
        let startIndex = attachmentIDs.count
        uploadTask?.cancel()
        uploadID = id
        isUploading = true
        uploadErrorMessage = nil
        uploadProgress = Double(startIndex) / Double(media.count)
        uploadTask = Task { [weak self] in
            await self?.uploadMedia(
                using: api, media: media, startingAt: startIndex, uploadID: id)
        }
    }

    private func uploadMedia(
        using api: any ChahuaAPIClient, media: [ShareMedia], startingAt startIndex: Int,
        uploadID: UUID
    ) async {
        do {
            guard let maximumFileSize else { throw ShareExtensionError.unavailable }
            for index in startIndex..<media.count {
                try Task.checkCancellation()
                guard self.uploadID == uploadID else { return }
                let item = media[index]
                guard item.byteCount <= maximumFileSize else {
                    throw ShareExtensionError.fileTooLarge(maximumFileSize)
                }
                let allocation = try await api.requestAttachmentUpload(
                    fileName: item.fileName, contentType: item.contentType, size: item.byteCount,
                    width: item.width, height: item.height, order: index)
                try Task.checkCancellation()
                guard self.uploadID == uploadID else { return }
                try await ShareAttachmentUploader.upload(file: item.url, allocation: allocation) {
                    [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.uploadID == uploadID else { return }
                        self.uploadProgress = (Double(index) + progress) / Double(media.count)
                    }
                }
                try Task.checkCancellation()
                guard self.uploadID == uploadID else { return }
                attachmentIDs.append(allocation.attachmentId)
            }
            guard self.uploadID == uploadID else { return }
            uploadProgress = 1
            isUploading = false
            uploadTask = nil
        } catch is CancellationError {
            guard self.uploadID == uploadID else { return }
            isUploading = false
            uploadTask = nil
        } catch {
            guard self.uploadID == uploadID else { return }
            isUploading = false
            uploadTask = nil
            uploadErrorMessage = Self.message(for: error)
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

    private static func loadDestinations(using api: any ChahuaAPIClient) async throws
        -> [ShareDestination]
    {
        async let chats = allChats(using: api)
        async let threads = allThreads(using: api)
        let (chatItems, threadItems) = try await (chats, threads)
        let chatByID = Dictionary(uniqueKeysWithValues: chatItems.map { ($0.id, $0) })
        let chatIDs = Set(chatItems.map(\.id)).union(threadItems.map(\.chatId))
        var access: [String: ShareChatAccess] = [:]
        for id in chatIDs {
            let info = try await api.groupInfo(chatID: id)
            guard info.id == id else { throw APIError.unexpectedResponse }
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
            }
            let item = chatByID[id]
            let peer = info.peer ?? item?.peer
            let title =
                item?.kind == .dm || info.kind == .dm
                ? peer?.username ?? item?.name ?? info.name ?? "Chat"
                : item?.name ?? info.name ?? "Chat"
            let avatarURL = (info.kind == .dm ? peer?.avatarUrl : info.avatar ?? item?.avatar)
                .flatMap(URL.init(string:))
            access[id] = ShareChatAccess(
                canWrite: canWrite, title: title, kind: info.kind, avatarURL: avatarURL,
                avatarName: title)
        }

        var destinations: [ShareDestination] = []
        destinations.reserveCapacity(chatItems.count + threadItems.count)
        for chat in chatItems where access[chat.id]?.canWrite == true {
            let detail = access[chat.id]!
            destinations.append(
                .chat(
                    chatID: chat.id, title: detail.title,
                    subtitle: chat.lastMessage.map { Self.previewText($0, fallback: "Message") },
                    activityDate: chat.lastMessageAt ?? .distantPast,
                    avatarURL: detail.avatarURL, avatarName: detail.avatarName))
        }
        for thread in threadItems where access[thread.chatId]?.canWrite == true {
            let detail = access[thread.chatId]!
            let root = thread.threadRootMessage
            let rootName = root.sender.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let badge: ShareDestination.AvatarBadge? =
                detail.kind == .dm
                ? .thread
                : rootName?.isEmpty == false
                    ? .person(
                        url: root.sender.avatarUrl.flatMap(URL.init(string:)), name: rootName!)
                    : nil
            destinations.append(
                .thread(
                    chatID: thread.chatId, threadID: root.id,
                    title: Self.previewText(root, fallback: "Message"),
                    subtitle: Self.previewText(thread.lastReply ?? root, fallback: "Message"),
                    activityDate: thread.lastReplyAt,
                    avatarURL: detail.avatarURL, avatarName: detail.avatarName, avatarBadge: badge))
        }
        return destinations.sorted {
            if $0.activityDate != $1.activityDate { return $0.activityDate > $1.activityDate }
            if $0.chatID != $1.chatID { return $0.chatID < $1.chatID }
            return $0.threadID < $1.threadID
        }
    }

    private static func allChats(using api: any ChahuaAPIClient) async throws -> [ChatListItem] {
        var chats: [ChatListItem] = []
        var after: String?
        repeat {
            let page = try await api.listChats(
                query: .init(limit: 100, after: after, archived: false))
            chats.append(contentsOf: page.chats)
            after = page.nextCursor
        } while after != nil
        return chats
    }

    private static func allThreads(using api: any ChahuaAPIClient) async throws -> [ThreadListItem]
    {
        var threads: [ThreadListItem] = []
        var before: String?
        repeat {
            let page = try await api.listThreads(
                query: .init(limit: 100, before: before, archived: false))
            threads.append(contentsOf: page.threads)
            before = page.nextCursor
        } while before != nil
        return threads
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

private struct ShareChatAccess {
    let canWrite: Bool
    let title: String
    let kind: ChatKind
    let avatarURL: URL?
    let avatarName: String
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
        let copied = try await copyFileRepresentation(
            from: provider, type: type, directory: directory, maximumFileSize: maximumFileSize)
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
            return try media(url: url, contentType: contentType, width: width, height: height)
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
    static func upload(
        file: URL, allocation: OutgoingUploadAllocation,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
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
        let delegate = ShareUploadProgress(onProgress: onProgress)
        onProgress(0)
        let (_, response) = try await session.upload(
            for: request, fromFile: file, delegate: delegate)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw ShareExtensionError.invalidUpload
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ShareExtensionError.uploadStatus(response.statusCode)
        }
        onProgress(1)
    }
}

private final class ShareUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onProgress(min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend))))
    }

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
