import ChahuaAPI
import CoreGraphics

#if os(macOS)
enum MacBubbleMediaLayout {
    struct Cell: Hashable {
        let attachment: AttachmentResponse
        let frame: CGRect
        let overflowCount: Int
    }

    struct Gallery: Hashable {
        let cells: [Cell]
        let size: CGSize
    }

    private static let gap: CGFloat = 2
    private static let partitions = [
        [[2], [1, 1]],
        [[3], [2, 1], [1, 2]],
        [[2, 2], [3, 1], [1, 3], [4]],
        [[2, 3], [3, 2], [1, 2, 2], [2, 2, 1], [1, 3, 1]],
        [[3, 3], [2, 2, 2], [4, 2], [2, 4], [2, 3, 1], [1, 3, 2]],
    ]

    static func bounds(viewport: CGSize, availableWidth: CGFloat) -> CGSize? {
        guard viewport.width.isFinite, viewport.height.isFinite, availableWidth.isFinite,
              viewport.width > 0, viewport.height > 0, availableWidth > 0 else { return nil }
        let width = min(viewport.width * 0.7, 420, availableWidth)
        let height = min(viewport.height * 0.6, 560)
        guard width > 0, height > 0 else { return nil }
        return .init(width: width, height: height)
    }

    static func singleSize(for attachment: AttachmentResponse, viewport: CGSize, availableWidth: CGFloat) -> CGSize? {
        guard let limits = bounds(viewport: viewport, availableWidth: availableWidth) else { return nil }
        var width = CGFloat(attachment.width ?? 0)
        var height = CGFloat(attachment.height ?? 0)
        guard width > 0, height > 0 else {
            let side = min(limits.width, limits.height)
            return .init(width: side, height: side)
        }
        let ratio = width / height
        let minimumWidth = min(120, limits.width)
        let minimumHeight = min(80, limits.height)
        if width > limits.width {
            width = limits.width
            height = width / ratio
        }
        if height > limits.height {
            height = limits.height
            width = height * ratio
        }
        if width < minimumWidth {
            let scale = minimumWidth / width
            if height * scale <= limits.height {
                width = minimumWidth
                height *= scale
            }
        }
        if height < minimumHeight {
            let scale = minimumHeight / height
            if width * scale <= limits.width {
                height = minimumHeight
                width *= scale
            }
        }
        // Extreme aspect ratios retain a minimum-sized container; the image remains contained.
        return .init(
            width: min(limits.width, max(width, minimumWidth)),
            height: min(limits.height, max(height, minimumHeight))
        )
    }

    static func gallery(for attachments: [AttachmentResponse], viewport: CGSize, availableWidth: CGFloat) -> Gallery? {
        guard let limits = bounds(viewport: viewport, availableWidth: availableWidth), attachments.count > 1 else { return nil }
        let items = attachments.prefix(6)
        let ratios = items.map { attachment -> CGFloat in
            let width = attachment.width.flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 100
            let height = attachment.height.flatMap { $0 > 0 ? CGFloat($0) : nil } ?? 100
            return min(2.5, max(0.5, width / height))
        }
        guard let (partition, rows) = bestRows(ratios: ratios, width: limits.width, height: limits.height) else { return nil }
        let interRowGaps = CGFloat(rows.count - 1) * gap
        let contentHeight = rows.reduce(0, +)
        let totalHeight = min(contentHeight + interRowGaps, limits.height)
        let scale = min(1, (limits.height - interRowGaps) / contentHeight)
        guard scale > 0 else { return nil }
        var cells: [Cell] = []
        cells.reserveCapacity(items.count)
        var index = 0
        var y: CGFloat = 0
        for (rowIndex, count) in partition.enumerated() {
            let rowHeight = min(rows[rowIndex] * scale, max(0, totalHeight - y))
            let rowWidth = limits.width - CGFloat(count - 1) * gap
            let sum = ratios[index ..< index + count].reduce(0, +)
            var x: CGFloat = 0
            for itemIndex in 0 ..< count {
                let isLast = itemIndex == count - 1
                let cellWidth = isLast ? limits.width - x : min(rowWidth * ratios[index + itemIndex] / sum, limits.width - x)
                let item = index + itemIndex
                cells.append(.init(
                    attachment: items[item],
                    frame: .init(x: x, y: y, width: cellWidth, height: rowHeight),
                    overflowCount: item == 5 && attachments.count > 6 ? attachments.count - 5 : 0
                ))
                x += cellWidth + gap
            }
            y += rowHeight + gap
            index += count
        }
        return .init(cells: cells, size: .init(width: limits.width, height: totalHeight))
    }

    private static func bestRows(ratios: [CGFloat], width: CGFloat, height: CGFloat) -> (partition: [Int], heights: [CGFloat])? {
        guard (2 ... 6).contains(ratios.count) else { return nil }
        var best: (partition: [Int], heights: [CGFloat])?
        var bestScore = CGFloat.infinity
        for partition in partitions[ratios.count - 2] {
            // Exact gaps are retained; defer layouts that leave no positive cell space.
            guard height > CGFloat(partition.count - 1) * gap,
                  partition.allSatisfy({ width > CGFloat($0 - 1) * gap }) else { continue }
            let rows = rowHeights(partition, ratios: ratios, width: width)
            guard rows.allSatisfy({ $0 > 0 }) else { continue }
            let candidateScore = score(rows, width: width, height: height)
            if candidateScore < bestScore {
                bestScore = candidateScore
                best = (partition, rows)
            }
        }
        return best
    }

    private static func rowHeights(_ partition: [Int], ratios: [CGFloat], width: CGFloat) -> [CGFloat] {
        var offset = 0
        return partition.map { count in
            defer { offset += count }
            return (width - CGFloat(count - 1) * gap) / ratios[offset ..< offset + count].reduce(0, +)
        }
    }

    private static func score(_ rows: [CGFloat], width: CGFloat, height: CGFloat) -> CGFloat {
        let total = rows.reduce(0, +) + CGFloat(rows.count - 1) * gap
        var result: CGFloat = total > 1.3 * height ? (total - height) * 10 : 0
        for row in rows {
            if row > 1.5 * width { result += row * 20 }
            if row < 0.15 * width { result += (0.15 * width - row) * 5 }
        }
        let average = rows.reduce(0, +) / CGFloat(rows.count)
        return result + rows.reduce(0) { $0 + abs($1 - average) }
    }
}

#endif
