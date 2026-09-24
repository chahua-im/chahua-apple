#if os(macOS)
    import AppKit
    import ChahuaAPI

    /// A single table-owned monitor intercepts context gestures before NSTextView can
    /// install its system menu. Ordinary left clicks remain native text selection.
    @MainActor
    final class TimelineContextSource {
        private weak var tableView: NSTableView?
        private var monitor: Any?
        private var selectionObserver: NSObjectProtocol?
        private weak var selectedTextView: AppKitMessageTextView?

        init(tableView: NSTableView) {
            self.tableView = tableView
        }

        func start() {
            guard monitor == nil, tableView?.window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown])
            { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
            selectionObserver = NotificationCenter.default.addObserver(
                forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.selectionDidChange(notification) }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
            monitor = nil
            selectionObserver = nil
            clearSelectedText()
        }

        deinit {
            MainActor.assumeIsolated {
                if let monitor { NSEvent.removeMonitor(monitor) }
                if let selectionObserver {
                    NotificationCenter.default.removeObserver(selectionObserver)
                }
            }
        }

        /// The interaction boundary uses top-origin window-content coordinates, not
        /// timeline coordinates. Header and composer insets must not be applied here.
        static func sourceRectangle(for bubbleView: NSView) -> CGRect? {
            guard let content = bubbleView.window?.contentView else { return nil }
            return topOrigin(bubbleView.convert(bubbleView.bounds, to: content), in: content)
        }

        @discardableResult
        static func openContextMenu(for rowView: TimelineRowView) -> Bool {
            guard let binding = rowView.binding,
                !binding.context.isInteractionPreview,
                case .message(let row) = binding.presentation.row,
                row.entry.messageType != .system,
                let open = binding.actions.openContextMenu,
                let bubble = binding.layout.frames[.bubble],
                let content = rowView.window?.contentView,
                !rowView.isHiddenOrHasHiddenAncestor,
                rowView.visibleRect.intersects(bubble)
            else { return false }
            open(
                row,
                MessageInteractionSource(
                    rect: topOrigin(rowView.convert(bubble, to: content), in: content),
                    presentation: binding.presentation, layout: binding.layout))
            return true
        }

        private func selectionDidChange(_ notification: Notification) {
            guard let tableView, let textView = notification.object as? AppKitMessageTextView,
                textView.isDescendant(of: tableView)
            else { return }
            guard textView.selectedRange().length > 0 else {
                if selectedTextView === textView { selectedTextView = nil }
                return
            }
            if selectedTextView !== textView { clearSelectedText() }
            selectedTextView = textView
        }

        private func clearSelectedText() {
            guard let previous = selectedTextView else { return }
            selectedTextView = nil
            let selection = previous.selectedRange()
            if selection.location != NSNotFound && selection.length > 0 {
                previous.setSelectedRange(NSRange(location: selection.location, length: 0))
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let tableView, let window = tableView.window, event.window === window,
                !tableView.isHiddenOrHasHiddenAncestor
            else { return event }
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) {
                if let previous = selectedTextView {
                    let point = tableView.convert(event.locationInWindow, from: nil)
                    let index = tableView.row(at: point)
                    if index >= 0,
                        let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                            as? TimelineTableCellView,
                        let bubble = cell.rowView.binding?.layout.frames[.bubble],
                        bubble.contains(cell.rowView.convert(event.locationInWindow, from: nil)),
                        !previous.isDescendant(of: cell)
                    {
                        clearSelectedText()
                    }
                }
                return event
            }
            guard event.type == .rightMouseDown || event.modifierFlags.contains(.control) else {
                return event
            }
            let point = tableView.convert(event.locationInWindow, from: nil)
            guard tableView.visibleRect.contains(point) else { return event }
            let index = tableView.row(at: point)
            guard index >= 0,
                let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                    as? TimelineTableCellView,
                let binding = cell.rowView.binding,
                let bubble = binding.layout.frames[.bubble],
                bubble.contains(cell.rowView.convert(event.locationInWindow, from: nil))
            else { return event }
            if let previous = selectedTextView, !previous.isDescendant(of: cell) {
                clearSelectedText()
            }
            guard Self.openContextMenu(for: cell.rowView) else { return event }
            return nil
        }

        private static func topOrigin(_ rect: CGRect, in content: NSView) -> CGRect {
            content.isFlipped
                ? rect
                : CGRect(
                    x: rect.minX, y: content.bounds.maxY - rect.maxY,
                    width: rect.width, height: rect.height)
        }
    }
#endif
