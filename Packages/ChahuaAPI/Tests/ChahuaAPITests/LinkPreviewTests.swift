import Foundation
import XCTest

@testable import ChahuaAPI

final class LinkPreviewTests: XCTestCase {
    func testExistingPreviewPayloadWithoutDescriptionRemainsValid() throws {
        let preview = try JSONDecoder().decode(
            MessageLinkPreview.self,
            from: Data(
                #"{"url":"https://example.com/article","status":"ready","title":"Article"}"#.utf8))
        XCTAssertEqual(preview.url, "https://example.com/article")
        XCTAssertNil(preview.description)
    }

    func testMetadataDecodesOptionalDescriptionPerPreview() throws {
        let metadata = try JSONDecoder().decode(
            MessageMetadataResponse.self,
            from: Data(
                """
                {"linkPreviews":[
                  {"url":"https://example.com/article","status":"ready",
                   "description":"A useful summary."},
                  {"url":"https://example.com/other","status":"ready","description":null}
                ]}
                """.utf8))
        XCTAssertEqual(metadata.linkPreviews.map(\.description), ["A useful summary.", nil])
    }

    func testShareSummaryMatchesBareURLsAndKeepsTitlesLiteral() {
        let sender = User(uid: 1, gender: 0, name: "Ada", avatarUrl: nil, userGroup: nil)
        let labels = MessagePreviewRenderer.Labels(
            attachment: "[File]", deleted: "[Deleted]", image: "[Image]", invite: "[Invite]",
            sticker: "[Sticker]", video: "[Video]", voiceMessage: "[Voice]", share: "[分享]")
        func preview(
            text: String = " \nHTTPS://EXAMPLE.COM:443\t", title: String? = nil,
            status: MessageLinkPreview.Status = .ready
        ) -> MessagePreview {
            MessagePreview(
                id: MessageID(1), clientGeneratedId: "one", createdAt: .distantPast,
                sender: sender, messageType: .text, message: text,
                metadata: .init(
                    linkPreviews: [.init(url: "https://example.com/", status: status, title: title)]
                ))
        }
        XCTAssertEqual(
            MessagePreviewRenderer.render(
                preview(title: "**Title** ||secret|| @[uid:1]"), labels: labels),
            "[分享]**Title** ||secret|| @[uid:1]")
        XCTAssertEqual(MessagePreviewRenderer.render(preview(), labels: labels), "[分享]example.com")
        XCTAssertEqual(
            MessagePreviewRenderer.render(preview(title: ""), labels: labels), "[分享]example.com")
        XCTAssertEqual(
            MessagePreviewRenderer.render(preview(title: "First\nsecond"), labels: labels),
            "[分享]First second")
        for status in [MessageLinkPreview.Status.pending, .unavailable, .disabled] {
            XCTAssertEqual(
                MessagePreviewRenderer.render(
                    preview(text: "https://example.com/", title: "Hidden", status: status),
                    labels: labels),
                "https://example.com/")
        }
    }

    func testShareSummaryRejectsNonStandaloneAndMismatchedMessages() {
        let sender = User(uid: 1, gender: 0, name: nil, avatarUrl: nil, userGroup: nil)
        let url = "https://example.com/article"
        let ready = MessageLinkPreview(url: url, status: .ready, title: "Article")
        func preview(
            text: String = "https://example.com/article", type: MessageType = .text,
            links: [MessageLinkPreview]? = nil,
            attachments: [MessagePreviewAttachment] = [], sticker: MessagePreviewSticker? = nil
        ) -> MessagePreview {
            MessagePreview(
                id: MessageID(1), clientGeneratedId: "one", createdAt: .distantPast,
                sender: sender, messageType: type, attachments: attachments, message: text,
                sticker: sticker, metadata: .init(linkPreviews: links ?? [ready]))
        }
        let labels = MessagePreviewRenderer.Labels(
            attachment: "file", deleted: "deleted", image: "image", invite: "invite",
            sticker: "sticker", video: "video", voiceMessage: "voice")
        let ordinary = [
            preview(text: "Read \(url)"), preview(text: "[Article](\(url))"),
            preview(text: "<\(url)>"), preview(text: "\(url) https://example.com/other"),
            preview(text: "https://other.example/article"),
            preview(text: "https://example.com/article#different"),
            preview(type: .system), preview(links: []), preview(links: [ready, ready]),
            preview(attachments: [.init(kind: "image/jpeg")]),
            preview(sticker: .init(emoji: "🙂")), preview().redactedForDeletion(),
        ]
        for item in ordinary {
            XCTAssertNil(
                MessagePreviewRenderer.sharedLinkSummary(item, labels: labels),
                item.message ?? "deleted")
        }
        XCTAssertEqual(
            MessagePreviewRenderer.render(preview().redactedForDeletion(), labels: labels),
            "deleted")
    }

    func testCompactMetadataSurvivesReplyForwardAndWireProjections() throws {
        let metadata = MessageMetadataResponse(
            linkPreviews: [
                .init(url: "https://example.com/article", status: .ready, title: "Article")
            ])
        let sender = User(uid: 1, gender: 0, name: "Ada", avatarUrl: nil, userGroup: nil)
        let full = MessageResponse(
            id: MessageID(1), chatId: "chat", clientGeneratedId: "one", messageType: .text,
            sender: sender, createdAt: .distantPast, message: "https://example.com/article",
            metadata: metadata)
        let compact = full.replyPreview
        XCTAssertEqual(compact.metadata, metadata)
        XCTAssertEqual(
            try JSONDecoder().decode(MessagePreview.self, from: JSONEncoder().encode(compact)),
            compact)
        var wire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(compact)) as? [String: Any])
        wire.removeValue(forKey: "messageType")
        let defaulted = try JSONDecoder().decode(
            MessagePreview.self, from: JSONSerialization.data(withJSONObject: wire))
        XCTAssertEqual(defaulted.messageType, .text)
        XCTAssertEqual(defaulted.metadata, metadata)
        let captured = ForwardedMessagePreviewResponse(
            originalMessageId: full.id, originalChatId: full.chatId, message: full.message,
            messageType: full.messageType, sender: sender, originalCreatedAt: full.createdAt,
            metadata: metadata)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ForwardedMessagePreviewResponse.self, from: JSONEncoder().encode(captured)),
            captured)
        XCTAssertEqual(captured.replyPreview.metadata, metadata)
        let forwarded = ForwardedMessageResponse(
            originalMessageId: full.id, originalChatId: full.chatId, message: full.message,
            messageType: full.messageType, sender: sender, originalCreatedAt: full.createdAt,
            reply: .internal(originalMessageId: full.id, preview: captured), metadata: metadata)
        XCTAssertEqual(forwarded.timelineMessage.replyPreview.metadata, metadata)
        XCTAssertEqual(forwarded.timelineMessage.replyToMessage?.metadata, metadata)
        XCTAssertNil(compact.redactedForDeletion().metadata)
        XCTAssertNil(full.redactedForDeletion().replyPreview.metadata)
    }

    func testCreateBodyEncodesOptionalPreviewChoicesWithoutChangingOmittedMetadata() throws {
        let body = CreateMessageBody(
            messageType: .text, clientGeneratedId: "one", message: "https://example.com",
            metadata: .init(linkPreviews: [.init(url: "https://example.com", status: .disabled)]))
        let data = try JSONEncoder().encode(body)
        XCTAssertEqual(try JSONDecoder().decode(CreateMessageBody.self, from: data), body)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try XCTUnwrap(wire["metadata"] as? [String: Any])
        let links = try XCTUnwrap(metadata["linkPreviews"] as? [[String: Any]])
        XCTAssertEqual(links.first?["status"] as? String, "disabled")
        let ordinary = CreateMessageBody(
            messageType: .text, clientGeneratedId: "two", message: "Hello")
        let ordinaryWire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ordinary)) as? [String: Any])
        XCTAssertNil(ordinaryWire["metadata"])
    }
}
