import CoreGraphics

enum TimelineSectionID: Hashable {
    case avatar, title, bubble, reply, media, audio, text, metadata, reactions, thread, standalone
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
    var standaloneSymbolSize: CGSize = .zero
    var standaloneLabelGap: CGFloat = 0
    /// Footer-local icon, reply label and trailing chevron rectangles.
    var threadContentFrames: [CGRect] = []

    static let empty = TimelineRowLayout(size: .zero, frames: [:], textGeometry: nil, mediaFrames: [], reactionFrames: [])

    func frame(for section: TimelineSectionID) -> CGRect? { frames[section] }
}

enum TimelineRowMetrics {
    static let rowHorizontalInset: CGFloat = 12
    static let rowVerticalInset: CGFloat = 4
    static let laneGap: CGFloat = 8
    static let titleGap: CGFloat = 4
    static let textHorizontalInset: CGFloat = 12
    static let textVerticalInset: CGFloat = 8
}

