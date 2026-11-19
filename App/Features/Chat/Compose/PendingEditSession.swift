import ChahuaAPI
import Combine
import Foundation

/// A queue-owned lease on one outgoing identity. Unsubmitted imports are never restored.
@MainActor
final class PendingEditSession: ObservableObject, Identifiable {
    let id: UUID
    let conversationKey: ConversationKey
    let clientGeneratedID: String
    let accountGeneration: UInt64
    let initialReplyToMessage: MessagePreview?
    let initialText: String
    let initialAttachments: [LocalOutgoingAttachment]
    let initialMetadata: MessageMetadataInput?
    @Published private(set) var attachments: [LocalOutgoingAttachment]
    @Published private(set) var replyToMessage: MessagePreview?
    @Published private(set) var compressionEnabled: Bool
    @Published private(set) var isValid = true
    @Published private(set) var isUploading = false
    @Published private(set) var error: String?
    private let initialTrimmedText: String
    private let initialDisabledURLs: Set<String>
    private let initialCompressionEnabled: Bool

    init(
        conversationKey: ConversationKey, clientGeneratedID: String,
        accountGeneration: UInt64, initialText: String,
        initialAttachments: [LocalOutgoingAttachment], initialMetadata: MessageMetadataInput?,
        initialReplyToMessage: MessagePreview?, compressionEnabled: Bool
    ) {
        id = UUID()
        self.conversationKey = conversationKey
        self.clientGeneratedID = clientGeneratedID
        self.accountGeneration = accountGeneration
        self.initialReplyToMessage = initialReplyToMessage
        self.initialText = initialText
        self.initialAttachments = initialAttachments
        self.initialMetadata = initialMetadata
        initialDisabledURLs = Self.disabledURLs(initialMetadata)
        initialTrimmedText = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = initialAttachments
        replyToMessage = initialReplyToMessage
        self.compressionEnabled = compressionEnabled
        initialCompressionEnabled = compressionEnabled
    }

    /// A missing payload leaves choices unchanged; an empty payload explicitly clears disables.
    /// Merely discovering enabled URLs in the editor is not a user modification.
    /// Progress and checkpoints on an existing generation are not editor changes.
    func hasChanges(text: String, metadata: MessageMetadataInput? = nil) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != initialTrimmedText
            || replyToMessage?.id != initialReplyToMessage?.id
            || compressionEnabled != initialCompressionEnabled
            || !attachments.elementsEqual(
                initialAttachments,
                by: {
                    $0.id == $1.id && $0.generation == $1.generation
                        && ($0.failure != nil || $1.failure == nil)
                })
            || (metadata.map { Self.disabledURLs($0) } ?? initialDisabledURLs)
                != initialDisabledURLs
    }

    private static func disabledURLs(_ metadata: MessageMetadataInput?) -> Set<String> {
        Set((metadata?.linkPreviews ?? []).lazy.filter { $0.status == .disabled }.map(\.url))
    }

    func replaceAttachments(_ value: [LocalOutgoingAttachment]) {
        guard isValid, attachments != value else { return }
        attachments = value
    }

    func setReplyToMessage(_ value: MessagePreview?) {
        guard isValid, replyToMessage != value else { return }
        replyToMessage = value
    }

    func setCompressionEnabled(_ value: Bool) {
        guard isValid, compressionEnabled != value else { return }
        compressionEnabled = value
    }

    func setUploading(_ value: Bool) {
        guard isUploading != value else { return }
        isUploading = value
    }

    func setError(_ value: String?) {
        guard error != value else { return }
        error = value
    }

    func invalidate() {
        guard isValid else { return }
        isValid = false
        setUploading(false)
    }
}
