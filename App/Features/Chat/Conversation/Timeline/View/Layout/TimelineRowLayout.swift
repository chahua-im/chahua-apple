import CoreGraphics

enum TimelineSectionID: Hashable {
    case avatar, title, bubble, reply, originalReply, origin, forwardedCard, media, audio, text,
        metadata, reactions, thread, standalone, linkPreviews
}

struct TimelineRowLayout {
    let size: CGSize
    let frames: [TimelineSectionID: CGRect]
    let textGeometry: MessageTextGeometry?
    let mediaFrames: [CGRect]
    let reactionFrames: [CGRect]
    /// Pill-local emoji, optional count, then avatar rectangles.
    var reactionContentFrames: [[CGRect]] = []
    var titleFrames: [CGRect] = []
    var replyContentFrames: [CGRect] = []
    var originalReplyContentFrames: [CGRect] = []
    var forwardedCardLayout: TimelineForwardedCardLayout?
    var linkPreviewFrames: [CGRect] = []
    var linkPreviewDescriptionHeights: [CGFloat] = []
    var standaloneSymbolSize: CGSize = .zero
    var standaloneLabelGap: CGFloat = 0
    /// Footer-local icon, reply label and trailing chevron rectangles.
    var threadContentFrames: [CGRect] = []

    static let empty = TimelineRowLayout(
        size: .zero, frames: [:], textGeometry: nil, mediaFrames: [], reactionFrames: [])

    func frame(for section: TimelineSectionID) -> CGRect? { frames[section] }

    /// Row-local reaction geometry shared by native visibility and reveal handling.
    func reactionRegion(in rowFrame: CGRect) -> CGRect? {
        guard let frame = frames[.reactions], frame.width > 0, frame.height > 0 else {
            return nil
        }
        return frame.offsetBy(dx: rowFrame.minX, dy: rowFrame.minY)
    }
}

enum TimelineRowMetrics {
    static let rowHorizontalInset: CGFloat = 12
    static let rowVerticalInset: CGFloat = 4
    static let laneGap: CGFloat = 8
    static let titleGap: CGFloat = 4
    static let textHorizontalInset: CGFloat = 12
    static let textVerticalInset: CGFloat = 8
}
