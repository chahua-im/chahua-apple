#if os(iOS)
import ChahuaAPI
import SwiftUI

private struct MessageBubbleActionsKey: EnvironmentKey {
    static var defaultValue: TimelineBubbleActions { .init() }
}

extension EnvironmentValues {
    var messageBubbleActions: TimelineBubbleActions {
        get { self[MessageBubbleActionsKey.self] }
        set { self[MessageBubbleActionsKey.self] = newValue }
    }
}

/// Separators render directly; every message shares one row container around its bubble.
struct TimelineBubbleView: View {
    let presentation: TimelineRowPresentation
    let layout: TimelineRowLayout
    let context: TimelineRowContext
    let actions: TimelineBubbleActions
    let mediaContext: AppMediaContext?

    init(presentation: TimelineRowPresentation, layout: TimelineRowLayout, context: TimelineRowContext, actions: TimelineBubbleActions = .init(), mediaContext: AppMediaContext? = nil) {
        self.presentation = presentation
        self.layout = layout
        self.context = context
        self.actions = actions
        self.mediaContext = mediaContext
    }

    var body: some View {
        Group {
            switch presentation.row {
            case .dateSeparator, .unreadSeparator:
                standalone
            case .message(let message):
                if message.entry.messageType == .system {
                    standalone
                } else {
                    MessageRowContainer(row: message, presentation: presentation, layout: layout, context: context)
                }
            }
        }
        .background {
            (context.isHighlighted ? ChahuaTheme.accent.opacity(0.15) : .clear)
                .animation(.easeOut(duration: 0.3), value: context.isHighlighted)
        }
        .environment(\.mediaContext, mediaContext)
        .environment(\.messageBubbleActions, actions)
        .environment(\.displayScale, presentation.environment.displayScale)
        .environment(\.locale, Locale(identifier: presentation.environment.localeIdentifier))
        .environment(\.timeZone, TimeZone(identifier: presentation.environment.timeZoneIdentifier) ?? .current)
        .environment(\.layoutDirection, presentation.environment.layoutDirection)
    }

    private var standalone: some View {
        TimelineSectionLayout(size: layout.size, frames: layout.frames) {
            if let frame = layout.frames[.standalone] {
                Group {
                    switch presentation.row {
                    case .dateSeparator:
                        DateSeparatorBubble(text: presentation.standaloneText ?? "", fontSize: presentation.environment.captionSize)
                    case .unreadSeparator:
                        Text(verbatim: presentation.standaloneText ?? "")
                            .font(.system(size: presentation.environment.captionSize))
                            .foregroundStyle(ChahuaTheme.ChatBubble.outgoingBackground)
                            .multilineTextAlignment(.center)
                    case .message(let message):
                        SystemMessageBubble(row: message, text: presentation.standaloneText ?? "")
                    }
                }
                .frame(width: frame.width, height: frame.height)
                .timelineSection(.standalone)
            }
        }
    }
}


#endif
