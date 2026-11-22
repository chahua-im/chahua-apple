#if os(macOS)
    import AppKit
    import ChahuaAPI
    import SwiftUI
    import UserNotifications
    import XCTest

    @testable import chahua_apple

    @MainActor
    final class ConversationScrollReturnMacTests: XCTestCase {
        func testChatToThreadBackRetainsScrollPosition() async throws {
            try await withShell { shell in
                let chat = try await self.position(shell, page: .chat, messageID: 1050, inset: 12)
                try self.openThread(in: shell)
                _ = try await self.position(shell, page: .thread, messageID: 2090, inset: 31)
                try await self.back(in: shell)
                try await self.assertReturned(shell, page: .chat, to: chat)
            }
        }

        func testChatToForwardedBackRetainsScrollPosition() async throws {
            try await withShell { shell in
                let chat = try await self.position(shell, page: .chat, messageID: 1050, inset: 12)
                try self.openForwarded(in: shell)
                _ = try await self.position(shell, page: .forwarded, messageID: 3090, inset: 31)
                try await self.back(in: shell)
                try await self.assertReturned(shell, page: .chat, to: chat)
            }
        }

        func testChatToThreadToForwardedBackRetainsEveryScrollPosition() async throws {
            try await withShell { shell in
                let chat = try await self.position(shell, page: .chat, messageID: 1050, inset: 12)
                try self.openThread(in: shell)
                let thread = try await self.position(
                    shell, page: .thread, messageID: 2050, inset: 23)
                try self.openForwarded(in: shell)
                _ = try await self.position(shell, page: .forwarded, messageID: 3090, inset: 37)
                try await self.back(in: shell)
                try await self.assertReturned(shell, page: .thread, to: thread)
                try await self.back(in: shell)
                try await self.assertReturned(shell, page: .chat, to: chat)
            }
        }

        func testForwardedToNestedForwardedBackRetainsEveryScrollPosition() async throws {
            try await withShell { shell in
                let chat = try await self.position(shell, page: .chat, messageID: 1050, inset: 12)
                try self.openForwarded(in: shell)
                let forwarded = try await self.position(
                    shell, page: .forwarded, messageID: 3050, inset: 23)
                try self.openForwarded(in: shell)
                _ = try await self.position(shell, page: .nested, messageID: 4090, inset: 37)
                try await self.back(in: shell)
                try await self.assertReturned(shell, page: .forwarded, to: forwarded)
                try await self.back(in: shell)
                try await self.assertReturned(shell, page: .chat, to: chat)
            }
        }

        private enum Page: UInt64 {
            case chat = 1000
            case thread = 2000
            case forwarded = 3000
            case nested = 4000

            func contains(_ id: MessageID) -> Bool {
                guard let value = UInt64(id.description) else { return false }
                return (rawValue..<(rawValue + 160)).contains(value)
            }
        }

        private struct Shell {
            let window: NSWindow
        }

        private struct Anchor {
            let messageID: MessageID
            let relativeOffset: CGFloat
        }

        // Launch the production shell through its public message-link entry point. In
        // particular, do not replace its conditional thread detail with a test router:
        // that would retain the chat controller and conceal the macOS regression.
        private func withShell(_ body: (Shell) async throws -> Void) async throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ConversationScrollReturnMac-\(UUID().uuidString)", isDirectory: true)
            let namespace = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
            let profile = try JSONDecoder().decode(
                MeResponse.self,
                from: Data(
                    #"{"uid":1,"username":"Ada","gender":0,"stickerPackOrder":[],"permissions":[]}"#
                        .utf8))
            let chat = ChatListItem(
                id: "27", name: "Scroll return regression", unreadCount: 0,
                archived: false, kind: .group)
            let chatMessages = try messages(page: .chat)
            let threadMessages = try messages(page: .thread)
            var pendingURL: URL? = try XCTUnwrap(
                MessagePermalink(chatID: "27", messageID: MessageID(1159))
            ).url
            let api = FakeChatAPI(chatResults: [.success(.init(chats: [chat]))])
            await api.setConversationPageMetadata(
                group: .init(id: "27", name: chat.name, myRole: .admin, kind: .group))
            await api.setNotificationMessage(try XCTUnwrap(chatMessages.last))
            await api.setPolicyMessagePage(chatMessages, chatID: "27")
            await api.setPolicyMessagePage(threadMessages, chatID: "27", threadID: "1050")
            await api.setForwardedResponses([
                try captured(page: .forwarded), try captured(page: .nested),
            ])
            let database = try await Task.detached {
                try ChahuaLocalStore(directory: directory, userID: 1)
            }.value
            let owner = AccountLocalStoreOwner { _ in database }
            let cache = AccountHistoryCache(owner: owner)
            cache.setSession(uid: 1)
            owner.setSession(uid: 1)
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api),
                historyCache: cache, onInvalidToken: {})
            store.currentUserProfile = profile
            let notifications = PushNotificationCoordinator(
                api: nil, namespace: namespace, defaults: defaults,
                authorizationStatusProvider: { .denied })
            let sceneID = UUID()
            let root = AuthenticatedShell(
                chatStore: store, notifications: notifications, notificationSceneID: sceneID,
                me: profile, isSigningOut: false, onSignOut: {},
                pendingURL: Binding(get: { pendingURL }, set: { pendingURL = $0 })
            )
            .environment(\.scenePhase, .active)
            .environment(\.conversationDisplayValues, ConversationDisplayValues())
            .defaultAppStorage(defaults)
            .modifier(MacConversationWindowChrome())
            let host = NSHostingController(rootView: AnyView(root))
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1000, height: 720))
            host.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 720)
            window.makeKeyAndOrderFront(nil)
            let shell = Shell(window: window)

            func cleanup() async throws {
                host.rootView = AnyView(EmptyView())
                host.view.layoutSubtreeIfNeeded()
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
                notifications.setVisibleConversation(sceneID: sceneID, conversation: nil)
                store.reset()
                await Task.yield()
                await cache.fenceForSignOut()
                owner.setSession(uid: nil)
                try await Task.detached { try database.close() }.value
                try FileManager.default.removeItem(at: directory)
                defaults.removePersistentDomain(forName: namespace)
            }

            do {
                await store.loadActiveChats()
                _ = try await settledTable(in: shell, page: .chat)
                try await body(shell)
            } catch {
                try await cleanup()
                throw error
            }
            try await cleanup()
        }

        private func messages(page: Page) throws -> [MessageResponse] {
            try (0..<160).map { index in
                var fields: [String: Any] = [:]
                if page == .thread { fields["replyRootId"] = "1050" }
                if index == 50 {
                    fields["forwardedBundleId"] = "root"
                    fields["forwardedPreview"] = [
                        "total": 160, "containsForwardedMessages": true, "messages": [],
                    ]
                    if page == .chat { fields["threadInfo"] = ["replyCount": 160] }
                }
                return try TimelineTestFixtures.message(
                    id: page.rawValue + UInt64(index), chatID: "27",
                    at: index % 60, minute: index / 60,
                    type: index == 50 ? .forwarded : .text,
                    text: String(
                        repeating: "History message \(page.rawValue + UInt64(index)). ", count: 5),
                    fields: fields)
            }
        }

        private func captured(page: Page) throws -> ForwardedMessagesResponse {
            let values = try (0..<160).map { index in
                let source = try TimelineTestFixtures.message(
                    id: page.rawValue + UInt64(index), chatID: "captured",
                    at: index % 60, minute: index / 60,
                    text: String(
                        repeating: "Captured history \(page.rawValue + UInt64(index)). ", count: 5))
                let isNestedCard = page == .forwarded && index == 50
                return ForwardedMessageResponse(
                    originalMessageId: source.id, originalChatId: source.chatId,
                    message: source.message, messageType: isNestedCard ? .forwarded : .text,
                    sender: source.sender, originalCreatedAt: source.createdAt,
                    forwardedBundleId: isNestedCard ? "child" : nil,
                    forwardedPreview: isNestedCard
                        ? .init(total: 160, containsForwardedMessages: false, messages: []) : nil)
            }
            return .init(total: values.count, messages: values)
        }

        private func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
            (root as? T).map { [$0] } ?? root.subviews.flatMap { views(type, in: $0) }
        }

        private func message(in table: NSTableView, row: Int, create: Bool = false)
            -> MessageResponse?
        {
            guard
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: create)
                    as? TimelineTableCellView,
                let binding = cell.rowView.binding,
                case .message(let message) = binding.presentation.row
            else { return nil }
            return message.entry.remoteMessage
        }

        private func visibleRows(in table: NSTableView) -> Range<Int> {
            guard let scroll = table.enclosingScrollView else { return 0..<0 }
            let range = table.rows(in: scroll.documentVisibleRect)
            guard range.location != NSNotFound else { return 0..<0 }
            return range.location..<min(NSMaxRange(range), table.numberOfRows)
        }

        private func table(in shell: Shell, page: Page) -> NSTableView? {
            guard let root = shell.window.contentView else { return nil }
            return views(NSTableView.self, in: root).first { table in
                table.delegate is TimelineTableViewController
                    && !table.isHiddenOrHasHiddenAncestor && !table.visibleRect.isEmpty
                    && visibleRows(in: table).contains { row in
                        message(in: table, row: row).map { page.contains($0.id) } == true
                    }
            }
        }

        // Observe stable native geometry, not the expected saved anchor: waiting for
        // the desired position would hide a real lost-position failure after Back.
        private func settledTable(in shell: Shell, page: Page) async throws -> NSTableView {
            var previous: String?
            var stableSamples = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                shell.window.contentView?.layoutSubtreeIfNeeded()
                shell.window.displayIfNeeded()
                guard let table = table(in: shell, page: page),
                    let scroll = table.enclosingScrollView,
                    table.numberOfRows >= 160, scroll.documentVisibleRect.height > 0
                else {
                    previous = nil
                    stableSamples = 0
                    continue
                }
                let rows = visibleRows(in: table)
                let exact =
                    !rows.isEmpty
                    && rows.allSatisfy { row in
                        guard
                            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                                as? TimelineTableCellView,
                            let binding = cell.rowView.binding
                        else { return false }
                        return abs(table.rect(ofRow: row).height - binding.layout.size.height) < 0.5
                            && abs(
                                binding.presentation.environment.timelineWidth - table.bounds.width)
                                < 0.5
                    }
                guard exact else {
                    previous = nil
                    stableSamples = 0
                    continue
                }
                let geometry = rows.map { row in
                    "\(message(in: table, row: row)?.id.description ?? "chrome"):\(table.rect(ofRow: row))"
                }.joined(separator: "|")
                let sample =
                    "\(ObjectIdentifier(table)):\(table.numberOfRows):\(scroll.documentVisibleRect):\(geometry)"
                stableSamples = sample == previous ? stableSamples + 1 : 0
                previous = sample
                if stableSamples >= 12 { return table }
            }
            return try XCTUnwrap(
                Optional<NSTableView>.none,
                "The real shell did not display a settled \(page) timeline")
        }

        private func anchor(in table: NSTableView) throws -> Anchor {
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            let row = try XCTUnwrap(
                visibleRows(in: table).first { message(in: table, row: $0) != nil })
            let id = try XCTUnwrap(message(in: table, row: row)?.id)
            return Anchor(
                messageID: id,
                relativeOffset: table.rect(ofRow: row).minY - scroll.documentVisibleRect.minY)
        }

        private func assertAwayFromLiveEdge(_ table: NSTableView) throws {
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            XCTAssertGreaterThan(
                table.bounds.maxY - scroll.documentVisibleRect.maxY, 200,
                "The regression must start in history, not at the newest message")
            XCTAssertGreaterThan(scroll.documentVisibleRect.minY, 200)
            XCTAssertFalse(visibleRows(in: table).contains(table.numberOfRows - 1))
        }

        private func position(
            _ shell: Shell, page: Page, messageID: UInt64, inset: CGFloat
        ) async throws -> Anchor {
            let table = try await settledTable(in: shell, page: page)
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            let row = try XCTUnwrap(
                (0..<table.numberOfRows).first {
                    message(in: table, row: $0, create: true)?.id == MessageID(messageID)
                })
            NotificationCenter.default.post(
                name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: table.rect(ofRow: row).minY + inset))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(
                name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(
                name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            let settled = try await settledTable(in: shell, page: page)
            try assertAwayFromLiveEdge(settled)
            let result = try anchor(in: settled)
            XCTAssertEqual(result.messageID, MessageID(messageID))
            XCTAssertEqual(result.relativeOffset, -inset, accuracy: 1)
            return result
        }

        private func assertReturned(_ shell: Shell, page: Page, to saved: Anchor) async throws {
            let table = try await settledTable(in: shell, page: page)
            let actual = try anchor(in: table)
            XCTAssertEqual(
                actual.messageID, saved.messageID, "Back must restore the same visible message")
            XCTAssertEqual(
                actual.relativeOffset, saved.relativeOffset, accuracy: 1,
                "Back must restore the message's relative pixel offset")
            try assertAwayFromLiveEdge(table)
        }

        private func openThread(in shell: Shell) throws {
            let table = try XCTUnwrap(table(in: shell, page: .chat))
            let button = try XCTUnwrap(
                visibleRows(in: table).lazy.compactMap { row -> NSButton? in
                    guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false)
                    else { return nil }
                    return self.views(NSButton.self, in: cell).first {
                        $0.action.map(NSStringFromSelector) == "openThread"
                            && $0.isEnabled && !$0.isHiddenOrHasHiddenAncestor
                    }
                }.first)
            button.performClick(nil)
        }

        private func openForwarded(in shell: Shell) throws {
            let root = try XCTUnwrap(shell.window.contentView)
            let card = try XCTUnwrap(
                views(TimelineForwardedCardView.self, in: root).first {
                    !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty && $0.isEnabled
                })
            card.performClick(nil)
        }

        private func back(in shell: Shell) async throws {
            let root = try XCTUnwrap(shell.window.contentView)
            let table = try XCTUnwrap(
                views(NSTableView.self, in: root).first {
                    $0.delegate is TimelineTableViewController
                        && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
                })
            // Same production in-pane Back hit target exercised by MacWindowChromeTests,
            // derived from the current timeline's detail origin rather than sidebar width.
            let detail = table.convert(table.bounds, to: root)
            let point = root.convert(
                NSPoint(x: detail.minX + 38, y: root.isFlipped ? 36 : root.bounds.height - 36),
                to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let release = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: point, modifierFlags: [],
                    timestamp: timestamp + 0.01,
                    windowNumber: shell.window.windowNumber, context: nil, eventNumber: 1,
                    clickCount: 1, pressure: 0))
            let press = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: point, modifierFlags: [], timestamp: timestamp,
                    windowNumber: shell.window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
            NSApp.postEvent(release, atStart: true)
            NSApp.sendEvent(press)
        }
    }
#endif
