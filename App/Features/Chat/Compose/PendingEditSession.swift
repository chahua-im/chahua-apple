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
    let capturedRevision: Int64
    let initialText: String
    let initialAttachments: [LocalEditAttachment]
    let initialMetadata: MessageMetadataInput?
    @Published private(set) var attachments: [LocalEditAttachment]
    @Published private(set) var isValid = true
    @Published private(set) var isUploading = false
    @Published private(set) var error: String?
    private var uploadedSelectionIdentities: [String: String] = [:]
    private enum SelectionIdentity: Equatable {
        case local(String)
        case server(String)
    }
    private let initialTrimmedText: String
    private let initialDisabledURLs: Set<String>

    init(
        id: UUID = UUID(), conversationKey: ConversationKey, clientGeneratedID: String,
        accountGeneration: UInt64, capturedRevision: Int64, initialText: String,
        initialAttachments: [LocalEditAttachment], initialMetadata: MessageMetadataInput? = nil
    ) {
        self.id = id
        self.conversationKey = conversationKey
        self.clientGeneratedID = clientGeneratedID
        self.accountGeneration = accountGeneration
        self.capturedRevision = capturedRevision
        self.initialText = initialText
        self.initialAttachments = initialAttachments
        self.initialMetadata = initialMetadata
        initialDisabledURLs = Self.disabledURLs(initialMetadata)
        initialTrimmedText = initialText.trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = initialAttachments
    }

    /// A missing payload leaves choices unchanged; an empty payload explicitly clears disables.
    /// Merely discovering enabled URLs in the editor is not a user modification.
    func hasChanges(text: String, metadata: MessageMetadataInput? = nil) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) != initialTrimmedText
            || !attachments.lazy.map(selectionIdentity)
                .elementsEqual(initialAttachments.lazy.map(selectionIdentity))
            || (metadata.map { Self.disabledURLs($0) } ?? initialDisabledURLs)
                != initialDisabledURLs
    }

    private static func disabledURLs(_ metadata: MessageMetadataInput?) -> Set<String> {
        Set((metadata?.linkPreviews ?? []).lazy.filter { $0.status == .disabled }.map(\.url))
    }

    static func selectionID(_ attachment: LocalEditAttachment) -> String {
        switch attachment {
        case .local(let slot): "local:\(slot.id)"
        case .server(let attachment): "server:\(attachment.id)"
        }
    }

    private func selectionIdentity(_ attachment: LocalEditAttachment) -> SelectionIdentity {
        switch attachment {
        case .local(let slot): return .local(slot.id)
        case .server(let server):
            if let original = uploadedSelectionIdentities[server.id] { return .local(original) }
            return .server(server.id)
        }
    }

    func replaceUploadedSlots(serverAttachments: [AttachmentResponse]) {
        guard !serverAttachments.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: serverAttachments.lazy.map { ($0.id, $0) })
        var updated = attachments
        for (index, selection) in attachments.enumerated() {
            guard case .local(let slot) = selection, let id = slot.attachmentID,
                let server = byID[id]
            else { continue }
            uploadedSelectionIdentities[id] = slot.id
            updated[index] = .server(server)
        }
        replaceAttachments(updated)
    }

    func replaceAttachments(_ value: [LocalEditAttachment]) {
        guard attachments != value else { return }
        attachments = value
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
