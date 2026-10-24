import CoreGraphics

/// Card-local geometry shared by native drawing and the timeline's cached measurement.
struct TimelineForwardedCardLayout {
    let size: CGSize
    let labelFrames: [CGRect]
    let dividerFrame: CGRect
    let metadataFrame: CGRect

    init(
        width: CGFloat, lineCount: Int, titleHeight: CGFloat, previewHeight: CGFloat,
        countHeight: CGFloat, metadataSize: CGSize, displayScale: CGFloat
    ) {
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.up) / scale }
        let width = max(0, width)
        let titleHeight = pixel(titleHeight)
        let previewHeight = pixel(previewHeight)
        let countHeight = pixel(countHeight)
        let previewCount = max(0, lineCount - 2)
        var frames: [CGRect] = []
        frames.reserveCapacity(lineCount)
        frames.append(CGRect(x: 0, y: 0, width: width, height: titleHeight))
        var y = titleHeight
        if previewCount > 0 {
            y += 8
            for index in 0..<previewCount {
                if index > 0 { y += 3 }
                frames.append(CGRect(x: 0, y: y, width: width, height: previewHeight))
                y += previewHeight
            }
        }
        y += 8
        dividerFrame = CGRect(x: 0, y: y, width: width, height: 1 / scale)
        y = pixel(dividerFrame.maxY + 8)
        let footerHeight = pixel(max(countHeight, metadataSize.height))
        let metadataWidth = min(width, metadataSize.width)
        metadataFrame = CGRect(
            x: width - metadataWidth, y: pixel(y + (footerHeight - metadataSize.height) / 2),
            width: metadataWidth, height: metadataSize.height)
        if lineCount > 1 {
            frames.append(
                CGRect(
                    x: 0, y: pixel(y + (footerHeight - countHeight) / 2),
                    width: max(0, width - metadataWidth - 12), height: countHeight))
        }
        labelFrames = frames
        size = CGSize(width: width, height: y + footerHeight)
    }
}
