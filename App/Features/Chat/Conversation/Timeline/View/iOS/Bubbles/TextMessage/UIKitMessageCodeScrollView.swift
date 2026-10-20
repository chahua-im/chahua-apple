#if os(iOS)
    import UIKit

    /// A native horizontal viewport is needed to keep no-wrap code selectable
    /// without changing the containing bubble's TextKit geometry or vertical scroll.
    final class MessageCodeScrollView: UIScrollView {
        private let codeView: UITextView
        private var attachment: MessageCodeAttachment?

        init() {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 1_000_000, height: 1_000_000))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            codeView = UITextView(frame: .zero, textContainer: container)
            super.init(frame: .zero)
            backgroundColor = MessageMarkdownStyle.codeBackground
            layer.cornerRadius = 6
            clipsToBounds = true
            alwaysBounceVertical = false
            alwaysBounceHorizontal = false
            showsVerticalScrollIndicator = false
            showsHorizontalScrollIndicator = true
            isDirectionalLockEnabled = true
            contentInsetAdjustmentBehavior = .never
            codeView.isEditable = false
            codeView.isSelectable = true
            codeView.isScrollEnabled = false
            codeView.backgroundColor = .clear
            codeView.textContainerInset = .zero
            codeView.dataDetectorTypes = []
            codeView.textContainer.widthTracksTextView = false
            codeView.textContainer.heightTracksTextView = false
            codeView.textContainer.size = CGSize(width: 1_000_000, height: 1_000_000)
            codeView.accessibilityLabel = "Code"
            addSubview(codeView)
        }

        required init?(coder: NSCoder) { nil }

        func apply(_ attachment: MessageCodeAttachment, allowsSelection: Bool) {
            codeView.isSelectable = allowsSelection
            if self.attachment !== attachment {
                codeView.textStorage.setAttributedString(attachment.attributedCode)
                self.attachment = attachment
                setContentOffset(.zero, animated: false)
            }
            let padding = MessageCodeAttachment.padding
            codeView.frame = CGRect(
                x: padding, y: padding,
                width: max(1, attachment.naturalSize.width - padding * 2),
                height: max(1, attachment.naturalSize.height - padding * 2))
            contentSize = attachment.naturalSize
        }
    }
#endif
