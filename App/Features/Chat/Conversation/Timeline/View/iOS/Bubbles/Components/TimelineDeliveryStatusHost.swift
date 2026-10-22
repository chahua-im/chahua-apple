#if os(iOS)
    import SwiftUI
    import UIKit

    /// Native timeline sections must retain cached TextKit geometry and selection;
    /// replacing the row with SwiftUI would remeasure it. Host only the shared status
    /// component, leaving retry hit testing and accessibility with the native section.
    @MainActor
    final class TimelineDeliveryStatusHost: UIView {
        private var content: MessageDeliveryStatusContent?
        private var contentView: (UIView & UIContentView)?
        private var requestedVisible = true

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            accessibilityElementsHidden = true
        }

        required init?(coder: NSCoder) { nil }

        func configure(_ metadata: MessageMetadata?) {
            content = metadata?.statusContent
            updateContent()
            setNeedsLayout()
        }

        func clear() {
            content = nil
            updateContent()
        }

        func setVisible(_ visible: Bool) {
            guard requestedVisible != visible else { return }
            requestedVisible = visible
            updateContent()
        }

        override var isHidden: Bool {
            didSet {
                guard isHidden != oldValue else { return }
                updateContent()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateContent()
        }

        private func updateContent() {
            let displaying = requestedVisible && window != nil && !isHidden
            guard contentView != nil || content != nil else { return }
            var content = content
            content?.isVisible = displaying
            let configuration = UIHostingConfiguration {
                Group {
                    if let content {
                        content
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .margins(.all, 0)
            .minSize(width: 0, height: 0)
            if let contentView {
                contentView.configuration = configuration
            } else {
                let view = configuration.makeContentView()
                view.backgroundColor = .clear
                view.isUserInteractionEnabled = false
                view.accessibilityElementsHidden = true
                addSubview(view)
                contentView = view
            }
            // The shared wrapper removes its animated subtree when not visible;
            // keep the native content view available for the next cell bind.
            contentView?.isHidden = !displaying || content == nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            contentView?.frame = bounds
        }
    }
#endif
