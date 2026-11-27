import CoreGraphics

/// Window-local, top-leading geometry. A fitting stack moves as a single unit.
/// Oversized messages stay at their source while controls gather at the press.
struct MessageOverlayLayout {
    let previewFrame: CGRect
    let reactionFrame: CGRect
    let actionsFrame: CGRect

    init(
        bounds: CGRect, source: CGRect, previewSize: CGSize, controlsWidth: CGFloat,
        reactionHeight: CGFloat, actionsHeight: CGFloat, isOutgoing: Bool,
        margin: CGFloat = 16, spacing: CGFloat = 8, pressPoint: CGPoint? = nil
    ) {
        let inset = min(margin, max(0, min(bounds.width, bounds.height) / 2 - 1))
        let usable = bounds.insetBy(dx: inset, dy: inset)
        let width = min(max(1, controlsWidth), usable.width)
        let reactionHeight = max(0, reactionHeight)
        let reactionSpace = reactionHeight > 0 ? reactionHeight + spacing : 0
        let actionsHeight = max(0, actionsHeight)
        let actionsSpace = actionsHeight > 0 ? actionsHeight + spacing : 0
        let previewWidth = min(max(1, previewSize.width), usable.width)
        let previewHeight = max(1, previewSize.height)
        let sourceX = source.isEmpty ? usable.midX - previewWidth / 2 : source.minX
        let sourceY = source.isEmpty ? usable.midY - previewHeight / 2 : source.minY
        let x = min(max(usable.minX, sourceX), usable.maxX - previewWidth)
        let stackHeight = reactionSpace + previewHeight + actionsSpace
        let tall = stackHeight > usable.height
        let y =
            tall
            ? sourceY
            : min(
                max(usable.minY + reactionSpace, sourceY),
                usable.maxY - previewHeight - actionsSpace)
        previewFrame = CGRect(x: x, y: y, width: previewWidth, height: previewHeight)
        let proposedControlsX = isOutgoing ? previewFrame.maxX - width : previewFrame.minX
        let controlsX = min(max(usable.minX, proposedControlsX), usable.maxX - width)
        if tall {
            // Keep a small gap centered on the actual press. VoiceOver/keyboard
            // invocation has no press, so use the visible portion's midpoint.
            let visible = previewFrame.intersection(usable)
            let fallbackY = visible.isNull ? usable.midY : visible.midY
            let anchorY = pressPoint?.y ?? fallbackY
            let gap = spacing * 2
            let controlsHeight = reactionHeight + actionsHeight + gap
            let top = min(
                max(usable.minY, anchorY - reactionHeight - spacing),
                max(usable.minY, usable.maxY - controlsHeight))
            reactionFrame = CGRect(
                x: controlsX, y: top, width: width, height: reactionHeight)
            actionsFrame = CGRect(
                x: controlsX, y: top + reactionHeight + gap,
                width: width, height: actionsHeight)
        } else {
            reactionFrame = CGRect(
                x: controlsX, y: y - reactionSpace, width: width, height: reactionHeight)
            actionsFrame = CGRect(
                x: controlsX, y: previewFrame.maxY + spacing,
                width: width, height: actionsHeight)
        }
    }
}
