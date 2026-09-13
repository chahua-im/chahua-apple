import CoreGraphics

enum TimelineSectionID: Hashable {
    case avatar, title, bubble, reply, media, text, metadata, reactions, thread, standalone
}

struct TimelineRowLayout {
    let size: CGSize
    let frames: [TimelineSectionID: CGRect]
    let textGeometry: MessageTextGeometry?
    let mediaFrames: [CGRect]
    let reactionFrames: [CGRect]
    var titleFrames: [CGRect] = []
    var standaloneSymbolSize: CGSize = .zero
    var standaloneLabelGap: CGFloat = 0
    var threadSymbolSize: CGSize = .zero
    var threadLabelGap: CGFloat = 0

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

