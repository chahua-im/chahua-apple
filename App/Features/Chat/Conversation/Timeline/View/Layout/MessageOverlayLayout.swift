import CoreGraphics

/// Window-local, top-leading geometry. The preview frame is a clipping viewport,
/// never a proposal for remeasuring the source bubble. Controls may cover its
/// lower portion when the original bubble and menu cannot both fit on screen.
struct MessageOverlayLayout {
    let previewFrame: CGRect
    let reactionFrame: CGRect
    let actionsFrame: CGRect

    init(
        bounds: CGRect, source: CGRect, previewSize: CGSize, controlsWidth: CGFloat,
        reactionHeight: CGFloat, actionsHeight: CGFloat, isOutgoing: Bool,
        margin: CGFloat = 16, spacing: CGFloat = 8
    ) {
        let inset = min(margin, max(0, min(bounds.width, bounds.height) / 2 - 1))
        let usable = bounds.insetBy(dx: inset, dy: inset)
        let width = min(max(1, controlsWidth), usable.width)
        let reactionHeight = min(max(0, reactionHeight), max(0, usable.height - spacing - 1))
        let reactionSpace = reactionHeight > 0 ? reactionHeight + spacing : 0
        let previewHeight = min(max(1, previewSize.height), max(1, usable.height - reactionSpace))
        let previewWidth = min(max(1, previewSize.width), usable.width)
        let actionsHeight = min(max(0, actionsHeight), max(1, usable.height - reactionSpace))
        let actionsSpace = actionsHeight > 0 ? actionsHeight + spacing : 0
        let sourceX = source.isEmpty ? usable.midX - previewWidth / 2 : source.minX
        let sourceY = source.isEmpty ? usable.midY - previewHeight / 2 : source.minY
        let x = min(max(usable.minX, sourceX), usable.maxX - previewWidth)
        let top = usable.minY + reactionSpace
        // Reserve room for both sections when possible. Oversized previews keep
        // their viewport instead of collapsing into a tiny thumbnail above menus.
        let bottom = max(top, usable.maxY - previewHeight - actionsSpace)
        let y = min(max(top, sourceY), bottom)
        previewFrame = CGRect(x: x, y: y, width: previewWidth, height: previewHeight)
        let proposedControlsX = isOutgoing ? previewFrame.maxX - width : previewFrame.minX
        let controlsX = min(max(usable.minX, proposedControlsX), usable.maxX - width)
        reactionFrame = CGRect(
            x: controlsX, y: y - reactionSpace, width: width, height: reactionHeight)
        actionsFrame = CGRect(
            x: controlsX, y: min(previewFrame.maxY + spacing, usable.maxY - actionsHeight),
            width: width, height: actionsHeight)
    }
}
