import ChahuaAPI

#if os(macOS)
    import AppKit
    import Combine
    import SwiftUI
    import XCTest
    @testable import chahua_apple

    @MainActor
    final class MacWindowChromeTests: XCTestCase {
        func testConversationSearchIncludesArchivedAndContinuesPastNonmatchingPages() async throws {
            let api = FakeChatAPI(
                chatResults: [
                    .success(
                        .init(
                            chats: [
                                .init(
                                    id: "main", name: "Product Crit", unreadCount: 0,
                                    archived: false, kind: .group)
                            ], nextCursor: "next")),
                    .success(
                        .init(chats: [
                            .init(
                                id: "dm", name: "Mika", unreadCount: 0, archived: false, kind: .dm)
                        ])),
                ],
                archivedChatResults: [
                    .success(
                        .init(chats: [
                            .init(
                                id: "archive", name: "Mika project", unreadCount: 42,
                                archived: true, kind: .group)
                        ]))
                ])
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            )
            defer { store.reset() }
            store.currentUserProfile = try JSONDecoder().decode(
                MeResponse.self,
                from: Data(
                    """
                    {"uid":1,"username":"Account 1","gender":0,"stickerPackOrder":[],"permissions":[]}
                    """.utf8))
            let model = ConversationSearchModel(currentUserID: 1, store: store)
            defer { model.stop() }
            model.query = "mika"
            model.start()
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while model.state(for: .active).isLoading || model.state(for: .archived).isLoading {
                guard ContinuousClock.now < deadline else {
                    return XCTFail("Search did not settle")
                }
                await Task.yield()
            }
            XCTAssertEqual(model.results(in: .archived).map(\.id), ["archive"])
            XCTAssertTrue(model.results(in: .active).isEmpty)
            XCTAssertTrue(model.state(for: .active).hasMore)
            model.loadMore(in: .active)
            while model.state(for: .active).isLoading {
                guard ContinuousClock.now < deadline else {
                    return XCTFail("Next page did not settle")
                }
                await Task.yield()
            }
            XCTAssertEqual(model.results(in: .active).map(\.id), ["dm"])
            XCTAssertFalse(model.state(for: .active).hasMore)
            model.reconcileSelection()
            model.moveSelection(by: 1)
            var openedChatID: String?
            model.open(
                onOpenChat: { openedChatID = $0.id },
                onOpenProfile: { _ in XCTFail("A chat selection must not open a profile") },
                onOpenInvite: { _ in XCTFail("A chat selection must not open an invite") })
            XCTAssertEqual(openedChatID, "archive")
            model.query = "product"
            XCTAssertEqual(model.results(in: .active).map(\.id), ["main"])
            XCTAssertTrue(model.results(in: .archived).isEmpty)
            model.query = "mika"
            store.currentUserProfile = nil
            XCTAssertFalse(model.isAvailable)
            XCTAssertTrue(model.results(in: .archived).isEmpty)
        }

        func testConversationSearchReusesLoadedChatsAndRejectsReplacedSession() async throws {
            let api = FakeChatAPI(
                chatResults: [
                    .success(
                        .init(chats: [
                            .init(
                                id: "main", name: "Product Crit", unreadCount: 0,
                                archived: false, kind: .group)
                        ]))
                ])
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            )
            defer { store.reset() }
            let profile = try JSONDecoder().decode(
                MeResponse.self,
                from: Data(
                    """
                    {"uid":1,"username":"Account 1","gender":0,"stickerPackOrder":[],"permissions":[]}
                    """.utf8))
            store.currentUserProfile = profile
            await store.loadActiveChats()
            let model = ConversationSearchModel(currentUserID: 1, store: store)
            defer { model.stop() }
            model.query = "product"
            model.start()
            XCTAssertEqual(model.results(in: .active).map(\.id), ["main"])
            model.query = "mika"
            XCTAssertTrue(model.results(in: .active).isEmpty)
            store.reset()
            store.currentUserProfile = profile
            model.start()
            XCTAssertFalse(model.isAvailable)
            XCTAssertTrue(model.results(in: .active).isEmpty)
        }

        func testSidebarSearchKeepsInputMountedAndMouseCancelClosesSearch() async throws {
            let selection = Selection()
            let host = NSHostingController(
                rootView: SelectionSurface(selection: selection, showsSearchSidebar: true))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            await settle(window)
            XCTAssertFalse(selection.isSearching, "Opening the window must not activate search")

            func input(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                return view.subviews.lazy.compactMap { input(in: $0) }.first
            }
            let original = try XCTUnwrap(input(in: host.view))
            let originalFrame = original.convert(original.bounds, to: nil)
            for query in ["", "mika"] {
                selection.query = query
                selection.isSearching = true
                selection.focusRequest += 1
                await settle(window)
                let active = try XCTUnwrap(input(in: host.view))
                XCTAssertTrue(active === original, "Activation must keep the original native input")
                XCTAssertEqual(active.convert(active.bounds, to: nil), originalFrame)

                let bitmap = try XCTUnwrap(
                    host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let capture = XCTAttachment(
                    data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                capture.name =
                    query.isEmpty ? "Empty search with cancel" : "Search query with cancel"
                capture.lifetime = .keepAlways
                add(capture)

                // Click the trailing cancel target in the actual 300pt sidebar.
                let fieldFrame = active.convert(active.bounds, to: host.view)
                let point = host.view.convert(
                    NSPoint(x: host.view.bounds.maxX - 33, y: fieldFrame.midY), to: nil)
                let timestamp = ProcessInfo.processInfo.systemUptime
                let release = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                let press = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: timestamp, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApp.postEvent(release, atStart: true)
                NSApp.sendEvent(press)
                await settle(window)
                XCTAssertFalse(
                    selection.isSearching, "Cancel must restore the list, not only clear text")
                XCTAssertEqual(selection.query, "")
                let inactive = try XCTUnwrap(input(in: host.view))
                XCTAssertTrue(inactive === original)
                XCTAssertEqual(inactive.convert(inactive.bounds, to: nil), originalFrame)
            }
            for query in ["", "mika"] {
                selection.query = query
                selection.isSearching = true
                selection.focusRequest += 1
                await settle(window)
                let escape = try XCTUnwrap(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                        isARepeat: false, keyCode: 53))
                NSApp.sendEvent(escape)
                await settle(window)
                XCTAssertEqual(selection.query, "")
                XCTAssertFalse(selection.isSearching, "One Escape must return to the list")
            }
        }

        func testArchiveSidebarKeepsWindowControlsAndRestoresMainScope() async throws {
            let api = FakeChatAPI(
                chatResults: [
                    .success(
                        .init(chats: [
                            .init(
                                id: "main", name: "Product Crit", unreadCount: 3, archived: false,
                                kind: .group)
                        ]))
                ],
                archivedChatResults: [
                    .success(
                        .init(chats: [
                            .init(
                                id: "archive", name: "Old Project", unreadCount: 42, archived: true,
                                kind: .group)
                        ]))
                ])
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            )
            defer { store.reset() }
            await store.loadActiveChats()
            await store.loadArchivedChats()
            var scope = ConversationListScope.messages
            let scopeBinding = Binding(get: { scope }, set: { scope = $0 })
            func surface(_ browsingArchived: Bool) -> some View {
                MacArchiveSidebar(
                    isArchived: browsingArchived,
                    activeBadges: ConversationTabBadges(),
                    archivedBadges: ConversationTabBadges(archived: true),
                    badgeColor: ConversationListPreferences.defaultUnreadBadgeColor,
                    selection: scopeBinding, onBack: {}
                ) {
                    MacSidebarSearchField(
                        query: .constant(""), isSearching: false, focusRequest: 0,
                        onActivate: {}, onClose: {}, onSubmit: {}, onMoveSelection: { _ in })
                } header: { opacity in
                    MacConversationListHeader(
                        isUpdating: false,
                        account: { Text("C") }, actions: { Image(systemName: "plus") }
                    )
                    .opacity(opacity)
                } list: { archived in
                    ChatListView(
                        store: store, drafts: store.drafts, currentUserID: 1,
                        scope: scopeBinding, archivedMode: archived,
                        showsExternalHeader: true, isActive: archived == browsingArchived,
                        selectedConversationID: nil, onSelectConversation: { _ in })
                } search: {
                    EmptyView()
                }
                .frame(width: 300, height: 560)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .light)
                .environment(\.isWideChatLayout, true)
                .modifier(MacConversationWindowChrome())
            }
            let host = NSHostingController(rootView: surface(false))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentViewController = host
            window.orderFront(nil)
            defer { window.close() }
            await settle(window)
            let original = try positions(in: window)
            for archived in [false, true, false] {
                host.rootView = surface(archived)
                try await Task.sleep(for: .milliseconds(400))
                await settle(window)
                try assertPositions(in: window, equalTo: original)
                let bitmap = try XCTUnwrap(
                    host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                let capture = XCTAttachment(
                    data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                    uniformTypeIdentifier: "public.png")
                capture.name = archived ? "Archived sidebar" : "Main sidebar"
                capture.lifetime = .keepAlways
                add(capture)
            }
            XCTAssertEqual(scope, .messages)
        }

        func testCircularJumpControlAndContentSizedUnreadChips() async throws {
            for text in ["1", "@", "99+"] {
                let chip = NSHostingView(
                    rootView: RoundChipLayout(isCircular: text.count == 1) {
                        Text(text).font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .frame(minHeight: 18)
                    }.background(.blue, in: Capsule(style: .circular)))
                let size = chip.fittingSize
                if text.count == 1 {
                    XCTAssertEqual(size.width, size.height, accuracy: 0.01)
                } else {
                    XCTAssertGreaterThan(size.width, size.height)
                }
            }
            let controls = TimelineNativeNavigationControls(
                frame: CGRect(x: 20, y: 20, width: 40, height: 120))
            controls.configure(
                showsLatest: true, messages: 1, mentions: 1, reactions: 0,
                busy: false, badgeColor: ConversationListPreferences.defaultUnreadBadgeColor)
            let root = NSView(frame: CGRect(x: 0, y: 0, width: 140, height: 180))
            root.addSubview(controls)
            let window = NSWindow(
                contentRect: root.bounds, styleMask: [.titled], backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.contentView = root
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            await settle(window)
            let bitmap = try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let capture = XCTAttachment(
                data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            capture.lifetime = .keepAlways
            add(capture)
        }

        func testNativeTrafficLightsStayFixedThroughConversationChanges() async throws {
            let selection = Selection()
            let host = NSHostingController(rootView: SelectionSurface(selection: selection))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentViewController = host
            window.orderFront(nil)
            defer { window.close() }
            await settle(window)
            let original = try positions(in: window)

            for title in ["First conversation", "Second conversation", nil] as [String?] {
                selection.chat = title
                // Check throughout SwiftUI's navigation-title update, not only
                // after AppKit finishes its next layout pass.
                for _ in 0..<10 {
                    try await Task.sleep(for: .milliseconds(20))
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    try assertPositions(in: window, equalTo: original)
                }
            }
            window.setContentSize(NSSize(width: 1000, height: 650))
            await settle(window)
            try assertPositions(in: window, equalTo: original)
        }

        func testForwardedBackStaysInDetailPaneAndPopsOneLevel() async throws {
            let api = FakeChatAPI()
            let store = ChatStore(
                apiClient: api, outgoingQueue: testOutgoingQueue(apiClient: api), onInvalidToken: {}
            )
            defer { store.reset() }
            var path = [1, 2]
            let surface = ChatSplitLayout(hasSelection: true) { _ in
                Text("Chats").frame(maxWidth: .infinity, maxHeight: .infinity)
            } detail: { _ in
                NavigationStack(path: Binding(get: { path }, set: { path = $0 })) {
                    Text("Conversation")
                        .navigationDestination(for: Int.self) { level in
                            ForwardedRecordsView(
                                store: store, chatID: "chat", messageID: MessageID(1),
                                bundleID: level == 2 ? "child" : nil)
                        }
                }
            }
            .frame(minWidth: 900, minHeight: 600)
            .modifier(MacConversationWindowChrome())
            let host = NSHostingController(rootView: surface)
            host.sizingOptions = []
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.contentViewController = host
            window.setContentSize(NSSize(width: 900, height: 600))
            host.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            await settle(window)
            let original = try positions(in: window)
            let bitmap = try XCTUnwrap(
                host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let capture = XCTAttachment(
                data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                uniformTypeIdentifier: "public.png")
            capture.name = "Forwarded messages detail header"
            capture.lifetime = .keepAlways
            add(capture)

            for remaining in [1, 0] {
                // The thread's Back target: sidebar + 16pt inset + half of 44pt.
                let point = host.view.convert(
                    NSPoint(x: 338, y: host.view.isFlipped ? 36 : host.view.bounds.height - 36),
                    to: nil)
                let timestamp = ProcessInfo.processInfo.systemUptime
                let release = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .leftMouseUp, location: point, modifierFlags: [],
                        timestamp: timestamp + 0.01, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
                let press = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .leftMouseDown, location: point, modifierFlags: [],
                        timestamp: timestamp, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                NSApp.postEvent(release, atStart: true)
                NSApp.sendEvent(press)
                await settle(window)
                XCTAssertEqual(
                    path.count, remaining, "Back must pop only the current detail level.")
                try assertPositions(in: window, equalTo: original)
            }
        }

        private func assertPositions(in window: NSWindow, equalTo original: [CGPoint]) throws {
            for (before, after) in zip(original, try positions(in: window)) {
                XCTAssertEqual(after.x, before.x, accuracy: 0.5)
                XCTAssertEqual(
                    after.y, before.y, accuracy: 0.5,
                    "Native window buttons should not shift when switching chats or resizing")
            }
        }
        private func settle(_ window: NSWindow) async {
            // SwiftUI title propagation and AppKit's subsequent frame notifications
            // run on separate turns of the main run loop.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(20))
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }

        private func positions(in window: NSWindow) throws -> [CGPoint] {
            try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { kind in
                let button = try XCTUnwrap(window.standardWindowButton(kind))
                XCTAssertFalse(
                    button.isHiddenOrHasHiddenAncestor,
                    "Native window controls must remain visible, not merely keep their old frames")
                XCTAssertGreaterThan(button.alphaValue, 0)
                let frame = button.convert(button.bounds, to: nil)
                return CGPoint(x: frame.minX, y: window.frame.height - frame.maxY)
            }
        }

        private final class Selection: ObservableObject {
            @Published var chat: String?
            @Published var isSearching = false
            @Published var query = ""
            @Published var focusRequest = 0
        }

        private struct SelectionSurface: View {
            @ObservedObject var selection: Selection
            var showsSearchSidebar = false

            var body: some View {
                if showsSearchSidebar {
                    MacArchiveSidebar(
                        isArchived: false, isSearching: selection.isSearching,
                        activeBadges: ConversationTabBadges(),
                        archivedBadges: ConversationTabBadges(archived: true),
                        badgeColor: ConversationListPreferences.defaultUnreadBadgeColor,
                        selection: .constant(.messages), onBack: {}
                    ) {
                        MacSidebarSearchField(
                            query: $selection.query, isSearching: selection.isSearching,
                            focusRequest: selection.focusRequest,
                            onActivate: { selection.isSearching = true },
                            onClose: {
                                selection.isSearching = false
                                selection.query = ""
                            },
                            onSubmit: {}, onMoveSelection: { _ in })
                    } header: { opacity in
                        MacConversationListHeader(
                            isUpdating: false, controlsOpacity: opacity,
                            account: { Text("C") }, actions: { Image(systemName: "plus") })
                    } list: { _ in
                        Text("Chats").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } search: {
                        Text("Search results").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(width: 300, height: 560)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, .light)
                    .environment(\.isWideChatLayout, true)
                } else {
                    ChatSplitLayout(hasSelection: selection.chat != nil) { _ in
                        Text("Chats").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } detail: { _ in
                        NavigationStack {
                            Group {
                                if let chat = selection.chat {
                                    Text(chat).navigationTitle(chat)
                                } else {
                                    Text("Select a conversation")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(minWidth: 900, minHeight: 600)
                    .modifier(MacConversationWindowChrome())
                }
            }
        }
    }
#endif
