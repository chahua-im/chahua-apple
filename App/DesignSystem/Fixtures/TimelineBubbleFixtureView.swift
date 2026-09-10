#if DEBUG
    import CoreText
    import ChahuaAPI
    import Combine
    import ImageIO
    import SwiftUI
    import UniformTypeIdentifiers

    /// Local-only diagnostic surface. Uses the production timeline and decoder, never production auth.
    struct TimelineBubbleFixtureView: View {
        @StateObject private var fixture = TimelineBubbleFixtureModel()
        @State private var dark = ProcessInfo.processInfo.arguments.contains("-fixture-dark")
        @State private var handlersEnabled = true
        @State private var event = "No action"
        @State private var threadScope = false
        @State private var draft = ""
        @State private var replyToMessage: MessagePreview?
        @State private var replyFocusRequest = 0

        var body: some View {
            if ProcessInfo.processInfo.arguments.contains("-fixture-split") {
                ChatSplitLayout(hasSelection: true) { _ in
                    VStack(alignment: .leading, spacing: 0) {
                        ConversationListHeader {
                            Menu {
                                Text("Alex")
                            } label: {
                                AvatarView(
                                    url: ProcessInfo.processInfo.environment["CHAHUA_FIXTURE_AVATAR"].map { URL(fileURLWithPath: $0) },
                                    displayName: "Alex", diameter: 26)
                            }
                        }
                        VStack(alignment: .leading, spacing: 16) {
                            Label(
                                "Native bubble timeline",
                                systemImage: "bubble.left.and.bubble.right")
                            Text("Drag the divider to resize the sidebar.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            diagnosticControls
                            Spacer()
                        }
                        .padding(16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } detail: { _ in
                    timelineContent
                        .modifier(
                            ChatHeaderOverlay {
                                ChatFloatingHeader(title: "Native bubble timeline")
                                    .padding(.horizontal, 12)
                                    .padding(.top, ChatSplitMetrics.outerInset)
                            })
                }
                .frame(minWidth: 900, minHeight: 600)
                .preferredColorScheme(dark ? .dark : .light)
            } else {
                timelineContent
            }
        }

        private var timelineContent: some View {
            VStack(spacing: 0) {
                if !ProcessInfo.processInfo.arguments.contains("-fixture-split") {
                    diagnosticControls
                }
                if let model = fixture.timeline {
                    MessageInteractionHost(
                        model: model,
                        context: .init(canWrite: handlersEnabled, isAdmin: true, isThreadView: threadScope),
                        actions: actions
                    ) { interactiveActions in
                        ConversationTimelineView(
                            model: model,
                            initialPosition: ProcessInfo.processInfo.environment["CHAHUA_FIXTURE_MESSAGE"].map(
                                TimelineInitialPosition.message) ?? .liveEdge,
                            actions: interactiveActions
                        )
                        .id(ObjectIdentifier(model))
                        .modifier(
                            ChatComposerOverlay {
                                MessageComposerView(
                                    text: $draft,
                                    maxHeight: 160,
                                    isEnabled: true,
                                    canSend: !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    onSubmit: {
                                        event = "Submitted: \(draft)" + (replyToMessage.map { " → \($0.id)" } ?? "")
                                        draft = ""
                                        replyToMessage = nil
                                    },
                                    replyToMessage: replyToMessage,
                                    replyFocusRequest: replyFocusRequest,
                                    onCancelReply: { replyToMessage = nil },
                                    onOpenReply: { id in Task { await model.jumpToMessage(id) } }
                                )
                            })
                    }
                } else if let error = fixture.error {
                    Text(error).textSelection(.enabled).padding()
                } else {
                    ProgressView("Generating local fixtures")
                }
            }
            .preferredColorScheme(dark ? .dark : .light)
            .navigationTitle("Native bubble timeline")
            .frame(minWidth: 300, minHeight: 400)
            .task { fixture.prepare() }
            .alert(
                "Couldn’t update reaction",
                isPresented: Binding(
                    get: { fixture.reactions.error != nil },
                    set: { if !$0 { fixture.reactions.error = nil } }
                )
            ) {
                Button("OK") { fixture.reactions.error = nil }
            } message: {
                Text(fixture.reactions.error ?? "")
            }
        }

        private var diagnosticControls: some View {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Dark", isOn: $dark)
                Toggle("Action hooks", isOn: $handlersEnabled)
                Toggle("Thread scope", isOn: $threadScope)
                    .onChange(of: threadScope) { value in fixture.setThreadScope(value) }
                HStack {
                    Button("Queue") { Task { await fixture.queue() } }
                        .disabled(fixture.hasQueued)
                    Button("Sending") {
                        fixture.store.markSending(chatID: "bubble-fixtures", clientGeneratedID: "diagnostic-pending")
                    }
                    Button("Fail") {
                        fixture.store.markFailed(chatID: "bubble-fixtures", clientGeneratedID: "diagnostic-pending")
                    }
                    Button("Acknowledge") { fixture.acknowledge() }
                }
                Button("Fail next reaction") { fixture.reactionClient.failNextMutation = true }
                Text(event).font(.caption).lineLimit(2)
            }
            .padding(8)
        }

        private var actions: TimelineBubbleActions {
            guard handlersEnabled else { return .init() }
            var result = TimelineBubbleActions()
            result.pendingReactionMessageIDs = fixture.reactions.pendingMessageIDs
            result.toggleReaction = { row, emoji in
                guard let message = row.entry.remoteMessage else { return }
                Task { await fixture.reactions.toggle(message: message, emoji: emoji, currentUserID: 1) }
            }
            result.openMedia = { source, attachments, selected in
                event = "Media: \(source) / \(selected), \(attachments.count) attachments"
            }
            result.replyToMessage = {
                replyToMessage = $0.replyPreview
                replyFocusRequest &+= 1
            }
            result.openReply = { id in Task { await fixture.timeline?.jumpToMessage(id) } }
            result.openThread = { event = "Thread: \($0)" }
            result.openLink = { event = "Link: \($0.absoluteString)" }
            result.openMention = { event = "Mention: \($0)" }
            return result
        }
    }

    @MainActor
private final class TimelineBubbleFixtureModel: ObservableObject, TimelineMessageSource {
    @Published var timeline: ConversationTimelineModel?
    @Published var error: String?
    @Published var hasQueued = false
    let store = ConversationMessageStore()
    let reactionClient = FixtureReactionClient()
    let reactions: MessageReactionController
    private var reactionObservation: AnyCancellable?
    private var messages: [MessageResponse] = []
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    init() {
        reactions = MessageReactionController(apiClient: reactionClient, messageStore: store, onInvalidToken: {})
        reactionObservation = reactions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    func prepare() {
        guard timeline == nil, error == nil else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chahua-bubble-fixtures", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sizes = [(1600, 900), (900, 1600), (40, 40), (2400, 100), (100, 2400)]
            var media: [[String: Any]] = []
            for (index, size) in sizes.enumerated() {
                let url = directory.appendingPathComponent("image-\(index).png")
                try generateImage(url: url, type: UTType.png.identifier, width: size.0, height: size.1, number: index)
                media.append(attachment(url: url, id: "image-\(index)", width: size.0, height: size.1))
            }
            let gif = directory.appendingPathComponent("animated.gif")
            try generateImage(url: gif, type: UTType.gif.identifier, width: 240, height: 180, number: 5, frames: 4)
            media.append(attachment(url: gif, id: "animated", width: 240, height: 180, kind: "image/gif"))
            let heic = directory.appendingPathComponent("native.heic")
            try generateImage(url: heic, type: UTType.heic.identifier, width: 320, height: 240, number: 6)
            media.append(attachment(url: heic, id: "heic", width: 320, height: 240, kind: "image/heic"))
            var objects: [[String: Any]] = []
            let texts = ["Hello", "Hello", "First line\n第二行 👨‍👩‍👧‍👦\nFinal line", String(repeating: "x", count: 160), "Literal *markup* and `code`; @[uid:2] @[uid:99] https://example.com/path)."]
            for (index, text) in texts.enumerated() { objects.append(object(index: index, text: text)) }
            for attachment in media { objects.append(object(index: objects.count, text: "", attachments: [attachment])) }
            var unknown = media[0]; unknown.removeValue(forKey: "width"); unknown.removeValue(forKey: "height")
            objects.append(object(index: objects.count, text: "Unknown dimensions remain square", attachments: [unknown]))
            let broken = attachment(url: directory.appendingPathComponent("missing.png"), id: "missing", width: 200, height: 150)
            objects.append(object(index: objects.count, text: "Missing image retains its frame", attachments: [broken]))
            for count in [2, 3, 4, 5, 6, 7, 20] {
                let attachments = (0 ..< count).map { index -> [String: Any] in
                    var item = media[index % media.count]; item["id"] = "gallery-\(count)-\(index)"; return item
                }
                var item = object(index: objects.count, text: "Gallery \(count): caption with reply and thread", attachments: attachments)
                item["replyToMessage"] = ["id": "quoted-target", "clientGeneratedId": "quoted-client", "createdAt": "2026-09-01T12:00:00Z", "sender": sender(2), "messageType": "text", "attachments": [["kind": "image/png"]], "mentions": [], "isDeleted": false, "message": "A quoted message with enough text to exercise truncation."]
                item["threadInfo"] = ["replyCount": count]
                item["isEdited"] = true
                objects.append(item)
            }
            for count in [0, 1, 5] {
                var item = object(index: objects.count, text: "", attachments: [media[0]])
                item["sender"] = sender(1)
                item["threadInfo"] = ["replyCount": count]
                item["isEdited"] = true
                objects.append(item)
            }
            for deleted in [false, true] {
                var item = object(index: objects.count, text: "A text reply with @[uid:2] and https://example.com")
                item["replyToMessage"] = [
                    "id": "fixture-0", "clientGeneratedId": "fixture-client-0",
                    "createdAt": "2026-09-01T12:00:00Z", "sender": sender(2),
                    "messageType": "text", "attachments": [], "mentions": [],
                    "isDeleted": deleted, "message": "Hello"
                ]
                objects.append(item)
            }
            let reactions: [[String: Any]] = [
                ["emoji": "👍", "count": 8, "reactedByMe": true, "reactors": (1 ... 5).map { ["uid": $0, "name": "Reactor \($0)"] }],
                ["emoji": "❤️", "count": 3, "reactedByMe": false],
                ["emoji": "🎉", "count": 2], ["emoji": "👀", "count": 1],
                ["emoji": "😂", "count": 1], ["emoji": "🔥", "count": 1]
            ]
            for outgoing in [false, true] {
                var item = object(index: objects.count, text: "Reactions wrap below the bubble")
                item["sender"] = sender(outgoing ? 1 : 2)
                item["reactions"] = reactions
                objects.append(item)
                var sticker = object(index: objects.count, text: "")
                sticker["sender"] = sender(outgoing ? 1 : 2)
                sticker["messageType"] = "sticker"
                sticker["sticker"] = [
                    "id": "fixture-sticker", "emoji": "🎉", "createdAt": "2026-09-01T12:00:00Z",
                    "media": ["id": "sticker-media", "url": gif.absoluteString, "contentType": "image/gif", "size": 1, "width": 240, "height": 180]
                ]
                sticker["reactions"] = reactions
                sticker["replyToMessage"] = [
                    "id": "quoted-target", "clientGeneratedId": "quoted-client",
                    "createdAt": "2026-09-01T12:00:00Z", "sender": sender(2),
                    "messageType": "text", "attachments": [], "mentions": [],
                    "isDeleted": false, "message": "A sticker reply uses the same preview."
                ]
                sticker["threadInfo"] = ["replyCount": 3]
                objects.append(sticker)
                var unsupported = object(index: objects.count, text: "")
                unsupported["sender"] = sender(outgoing ? 1 : 2)
                unsupported["messageType"] = "file"
                unsupported["reactions"] = [["emoji": "👍", "count": 2]]
                objects.append(unsupported)
            }
            let video = attachment(url: directory.appendingPathComponent("placeholder.mp4"), id: "video-placeholder", width: 320, height: 180, kind: "video/mp4")
            objects.append(object(index: objects.count, text: "Video stays a placeholder", attachments: [video]))
            for name in ["Ada", "", "System"] {
                var item = object(index: objects.count, text: "joined the chat\nSystem messages have no avatar or bubble background")
                item["messageType"] = "system"
                item["sender"] = ["uid": 2, "name": name, "gender": 0]
                item["isDeleted"] = name == "System"
                objects.append(item)
            }
            if let count = ProcessInfo.processInfo.environment["CHAHUA_PERFORMANCE_ROWS"].flatMap(Int.init) {
                for _ in objects.count ..< max(objects.count, count) {
                    objects.append(object(index: objects.count, text: String(repeating: "Scroll and resize wrapped text with selectable content. ", count: 4)))
                }
            }
            messages = try objects.map { try decoder.decode(MessageResponse.self, from: JSONSerialization.data(withJSONObject: $0)) }
            reactionClient.install(messages)
            timeline = ConversationTimelineModel(chatID: "bubble-fixtures", currentUserID: 1, isGroupChat: true, source: self, messageStore: store)
        } catch { self.error = "Fixture generation failed: \(error)" }
    }

    func queue() async {
        guard let timeline, !hasQueued else { return }
        hasQueued = true
        store.enqueue(.init(chatID: "bubble-fixtures", clientGeneratedID: "diagnostic-pending", body: .init(messageType: .text, clientGeneratedId: "diagnostic-pending", message: "Pending acknowledgement retains row identity"), enqueuedAt: Date(), senderID: 1, state: .queued))
        await timeline.revealLatestAfterSend()
    }

    func acknowledge() {
        do {
            var value = object(index: 100, text: "Acknowledged without a duplicate row")
            value["clientGeneratedId"] = "diagnostic-pending"
            value["sender"] = sender(1)
            value["createdAt"] = ISO8601DateFormatter().string(from: Date())
            if let threadID = timeline?.threadID { value["replyRootId"] = threadID }
            let message = try decoder.decode(MessageResponse.self, from: JSONSerialization.data(withJSONObject: value))
            store.apply(.message(message))
        } catch { self.error = String(describing: error) }
    }
    func setThreadScope(_ enabled: Bool) {
        timeline = ConversationTimelineModel(chatID: "bubble-fixtures", currentUserID: 1, isGroupChat: true, source: self, messageStore: store, threadID: enabled ? "fixture-root" : nil)
    }


    func fetchMessages(chatID: String, query: ListMessagesQuery) async throws -> ListMessagesResponse {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try JSONSerialization.data(withJSONObject: [
            "messages": try messages.map { message in
                var object = try JSONSerialization.jsonObject(with: encoder.encode(message)) as! [String: Any]
                if let threadID = query.threadID { object["replyRootId"] = threadID }
                return object
            },
            "olderCursor": NSNull(), "newerCursor": NSNull(), "nextCursor": NSNull(), "prevCursor": NSNull()
        ])
        return try decoder.decode(ListMessagesResponse.self, from: data)
    }

    private func sender(_ id: Int) -> [String: Any] { ["uid": id, "gender": 0, "name": id == 1 ? "Me" : "Ada"] }
    private func object(index: Int, text: String, attachments: [[String: Any]] = []) -> [String: Any] {
        ["id": "fixture-\(index)", "clientGeneratedId": "fixture-client-\(index)", "chatId": "bubble-fixtures", "messageType": "text", "sender": sender(index % 2 == 0 ? 2 : 1), "createdAt": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_788_264_000 + Double(index))), "isEdited": false, "isDeleted": false, "hasAttachments": !attachments.isEmpty, "attachments": attachments, "reactions": [], "mentions": [["uid": 2, "gender": 0, "username": "Ada"]], "message": text]
    }
    private func attachment(url: URL, id: String, width: Int, height: Int, kind: String = "image/png") -> [String: Any] {
        ["id": id, "url": url.absoluteString, "kind": kind, "size": 1, "fileName": url.lastPathComponent, "width": width, "height": height]
    }

    private func generateImage(url: URL, type: String, width: Int, height: Int, number: Int, frames: Int = 1) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames, nil) else { throw CocoaError(.fileWriteUnknown) }
        if frames > 1 { CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary) }
        for frame in 0 ..< frames {
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw CocoaError(.fileWriteUnknown) }
            let shade = CGFloat((number + frame) % 10) / 10
            context.setFillColor(CGColor(red: 0.3 + shade * 0.5, green: 0.75 - shade * 0.4, blue: 0.65, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let label = NSAttributedString(string: "Fixture \(number) / frame \(frame)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, CGFloat(min(width, height)) / 8, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 8, y: 8)
            CTLineDraw(CTLineCreateWithAttributedString(label), context)
            guard let cgImage = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            let properties: [CFString: Any] = frames > 1 ? [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.3]] : [:]
            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
