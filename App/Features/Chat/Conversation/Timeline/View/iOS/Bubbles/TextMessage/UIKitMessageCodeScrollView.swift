#if os(iOS)
    import UIKit

    /// The fixed native header shares the measured TextKit attachment with the
    /// selectable horizontal viewport. SwiftUI cannot embed its controls into this
    /// native selection graph without introducing a second sizing/reuse owner.
    final class MessageCodeScrollView: UIView {
        private let scrollView = UIScrollView()
        private let codeView: UITextView
        private let header = UIView()
        private let languageLabel = UILabel()
        let copyButton = UIButton(type: .system)
        private let copyController = MessageCodeCopyController()
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
            layer.cornerRadius = 8
            clipsToBounds = true
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            scrollView.showsVerticalScrollIndicator = false
            scrollView.showsHorizontalScrollIndicator = true
            scrollView.isDirectionalLockEnabled = true
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.delaysContentTouches = false
            codeView.isEditable = false
            codeView.isSelectable = true
            codeView.isScrollEnabled = false
            codeView.backgroundColor = .clear
            codeView.textContainerInset = .zero
            codeView.dataDetectorTypes = []
            codeView.accessibilityLabel = AppLanguage.localized("Code")
            languageLabel.lineBreakMode = .byTruncatingTail
            copyButton.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 14, weight: .regular), forImageIn: .normal)
            copyButton.addTarget(self, action: #selector(copyCode), for: .touchUpInside)
            addSubview(scrollView)
            scrollView.addSubview(codeView)
            addSubview(header)
            header.addSubview(languageLabel)
            header.addSubview(copyButton)
            copyController.onChange = { [weak self] in self?.updateCopyFeedback() }
            updateCopyFeedback()
        }

        required init?(coder: NSCoder) { nil }

        func apply(
            _ attachment: MessageCodeAttachment, allowsSelection: Bool, copyEnabled: Bool = true
        ) {
            backgroundColor = attachment.backgroundColor
            header.backgroundColor = attachment.headerBackground
            languageLabel.font = attachment.headerFont
            languageLabel.textColor = attachment.headerForeground
            copyButton.tintColor = attachment.headerForeground
            codeView.isSelectable = allowsSelection
            copyController.isEnabled = copyEnabled
            copyButton.isEnabled = copyEnabled
            if self.attachment !== attachment {
                copyController.reset()
                codeView.selectedRange = NSRange(location: 0, length: 0)
                codeView.textStorage.setAttributedString(attachment.attributedCode)
                languageLabel.text = attachment.language ?? ""
                self.attachment = attachment
                scrollView.setContentOffset(.zero, animated: false)
            }
            codeView.frame = CGRect(
                x: MessageCodeAttachment.horizontalPadding,
                y: MessageCodeAttachment.verticalPadding,
                width: max(
                    1, attachment.codeSize.width - MessageCodeAttachment.horizontalPadding * 2),
                height: max(
                    1, attachment.codeSize.height - MessageCodeAttachment.verticalPadding * 2))
            scrollView.contentSize = attachment.codeSize
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let attachment else { return }
            let height = attachment.headerHeight
            header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
            let buttonWidth = min(24, bounds.width)
            copyButton.frame = CGRect(
                x: max(0, bounds.width - buttonWidth - 2), y: 0,
                width: buttonWidth, height: height)
            languageLabel.frame = CGRect(
                x: 6, y: 0, width: max(0, copyButton.frame.minX - 8 - 6), height: height)
            scrollView.frame = CGRect(
                x: 0, y: height, width: bounds.width, height: max(0, bounds.height - height))
        }

        @objc private func copyCode() {
            guard let attachment else { return }
            copyController.copy(attachment.code)
        }

        private func updateCopyFeedback() {
            copyButton.setImage(UIImage(systemName: copyController.status.symbol), for: .normal)
            copyButton.accessibilityLabel = copyController.status.label
            copyButton.toolTip = copyController.status.label
        }
    }
#endif
