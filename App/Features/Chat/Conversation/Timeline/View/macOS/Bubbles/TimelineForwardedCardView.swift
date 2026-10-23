#if os(macOS)
    import AppKit

    /// Native labels consume the timeline engine's cached card rectangle, including menu previews.
    @MainActor
    final class TimelineForwardedCardView: NSButton {
        var onActivate: (() -> Void)?
        private var labels: [NSTextField] = []
        private var lineCount = 0
        private let divider = NSBox()
        override var isFlipped: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            title = ""
            isBordered = false
            target = self
            action = #selector(activate)
            divider.boxType = .separator
            addSubview(divider)
        }
        required init?(coder: NSCoder) { nil }

        func configure(lines: [String], fontSize: CGFloat, outgoing: Bool, enabled: Bool) {
            lineCount = lines.count
            while labels.count < lines.count {
                let label = NSTextField(labelWithString: "")
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                addSubview(label)
                labels.append(label)
            }
            for (index, label) in labels.enumerated() {
                label.isHidden = index >= lines.count
                guard index < lines.count else { continue }
                label.stringValue = lines[index]
                label.font = .systemFont(
                    ofSize: fontSize, weight: index == 0 ? .semibold : .regular)
                label.textColor =
                    outgoing
                    ? NSColor.white.withAlphaComponent(index == 0 ? 1 : 0.7)
                    : index == 0 ? .labelColor : .secondaryLabelColor
            }
            isEnabled = enabled
            setAccessibilityLabel(lines.joined(separator: ", "))
            needsLayout = true
        }
        override func layout() {
            super.layout()
            let height = bounds.height / CGFloat(max(1, lineCount))
            for (index, label) in labels.prefix(lineCount).enumerated() {
                label.frame = CGRect(
                    x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
            }
            divider.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: 1)
        }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard !isHidden, bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func resetCursorRects() {
            if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
        }
        @objc private func activate() { if isEnabled { onActivate?() } }
    }
#endif
