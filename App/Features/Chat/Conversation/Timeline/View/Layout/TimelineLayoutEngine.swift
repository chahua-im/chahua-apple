import ChahuaAPI
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct TimelineLayoutEngine {
    // A single bounded scratch TextKit graph, never attached to a rendering view.
    private let textMeasurer = MessageTextLayout()

    func layout(_ content: TimelineRowPresentation, environment: TimelineLayoutEnvironment) -> TimelineRowLayout {
        guard environment.timelineWidth.isFinite, environment.timelineWidth > 0 else { return .empty }
        switch content.row {
        case .dateSeparator, .unreadSeparator:
            return standalone(content, environment: environment)
        case .message(let row):
            if row.entry.messageType == .system { return standalone(content, environment: environment) }
            return message(row, presentation: content, environment: environment)
        }
    }

    private func message(_ row: TimelineMessageRow, presentation p: TimelineRowPresentation, environment e: TimelineLayoutEnvironment) -> TimelineRowLayout {
        let scale = e.displayScale.isFinite && e.displayScale > 0 ? e.displayScale : 1
        let c = floor(e.centralWidth * scale) / scale
        guard c >= 1 else {
            return .init(size: CGSize(width: e.timelineWidth, height: pixel(e.avatarSize + 8, e)), frames: [:], textGeometry: nil, mediaFrames: [], reactionFrames: [])
        }
        let centralX = pixel(12 + e.avatarSize + 8, e)
        let text = row.entry.text ?? ""
        let deleted = row.entry.remoteMessage?.isDeleted == true
        let sticker = row.entry.messageType == .sticker && !deleted
        let supported = row.entry.messageType == .text && !deleted
        let hasBody = supported && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let remote = supported ? row.entry.remoteMessage?.attachments ?? [] : []
        let local: [LocalOutgoingAttachment]
        if supported, case .pending(let pending) = row.entry { local = pending.attachments } else { local = [] }
        let mediaCount = local.isEmpty ? remote.count : local.count
        let preferredMedia = local.isEmpty ? BubbleMediaLayout.size(for: remote, availableWidth: c) : BubbleMediaLayout.size(for: local, availableWidth: c)
        let hasMedia = preferredMedia != nil
        let metadata = p.metadata
        var preferredText: CGFloat = 0
        if hasBody {
            textMeasurer.update(attributedText: MessageTextContent.attributedText(text: text, mentions: row.entry.remoteMessage?.mentions ?? [], currentUserID: nil, isOutgoing: row.isOutgoing, font: .systemFont(ofSize: e.bodySize)), metadata: hasMedia ? nil : metadata)
            preferredText = textMeasurer.idealSize.width + 24
        }
        var labelFont = BubbleNativeFont.systemFont(ofSize: e.bodySize)
        if deleted {
            #if os(macOS)
            labelFont = NSFontManager.shared.convert(labelFont, toHaveTrait: .italicFontMask)
            #else
            if let descriptor = labelFont.fontDescriptor.withSymbolicTraits(.traitItalic) { labelFont = BubbleNativeFont(descriptor: descriptor, size: e.bodySize) }
            #endif
        }
        let unsupported = !supported && !sticker && !deleted
        let symbolSize = unsupported ? MessageNativeSymbol.size("questionmark.square.dashed", fontSize: e.bodySize, semibold: false) : .zero
        if let label = p.standaloneText {
            preferredText = nativeSize(label, font: labelFont).width + 24 + (unsupported ? symbolSize.width + 8 : 0)
        }
        let preferredTitle = p.title.map { titleGeometry($0, width: max(0, c - 24), environment: e).size.width + 24 } ?? 0
        let replySizes = p.reply.map { reply in
            let author = reply.sender.name.flatMap { $0.isEmpty ? nil : $0 } ?? "User \(reply.sender.uid)"
            return (
                author: singleLineSize(author, size: e.captionSize * 11 / 12, weight: .semibold),
                preview: singleLineSize(messagePreview(reply), size: e.captionSize)
            )
        }
        // Include the quote's stripe/text insets and the bubble's side padding.
        let preferredReply = replySizes.map { max($0.author.width, $0.preview.width) + 19 + 24 } ?? 0
        let threadContent: (symbol: CGSize, label: CGSize, chevron: CGSize)? = p.threadLabel.map { label in
            (
                symbol: MessageNativeSymbol.size("bubble.left.and.bubble.right.fill", fontSize: e.bodySize, semibold: false),
                label: singleLineSize(label, size: e.bodySize),
                chevron: MessageNativeSymbol.size("chevron.right", fontSize: e.bodySize, semibold: false)
            )
        }
        let preferredThread: CGFloat = threadContent.map { content in
            let itemsWidth = content.symbol.width + content.label.width + content.chevron.width
            return itemsWidth + (6 + 12 + 24)
        } ?? 0
        let preferred = max(preferredMedia?.width ?? 0, preferredText, metadata.map { $0.size.width + 24 } ?? 0, preferredTitle)
        let b = min(c, pixel(max(sticker ? 200 : preferred, preferredReply, preferredThread), e))
        let bubbleX = centralX + (row.isOutgoing ? c - b : 0)
        let innerWidth = min(b, max(1, b - 24))
        let inset = max(0, (b - innerWidth) / 2)
        let displayedSymbolSize = scaled(symbolSize, width: innerWidth)
        let standaloneGap = unsupported ? min(8, max(0, innerWidth - displayedSymbolSize.width)) : 0
        var frames: [TimelineSectionID: CGRect] = [:]
        var titleFrames: [CGRect] = []
        var replyContentFrames: [CGRect] = []
        var y: CGFloat = 4
        let bubbleY = y
        var height: CGFloat = 0
        if let title = p.title {
            let titleLayout = titleGeometry(title, width: innerWidth, environment: e, fillsWidth: true)
            titleFrames = titleLayout.frames
            height += 8
            frames[.title] = CGRect(x: bubbleX + inset, y: bubbleY + height, width: innerWidth, height: titleLayout.size.height)
            height += titleLayout.size.height + 4
        }
        if let replySizes {
            let authorHeight = pixel(replySizes.author.height, e)
            let previewHeight = pixel(replySizes.preview.height, e)
            let replyHeight = authorHeight + 2 + previewHeight + 8
            let labelWidth = max(0, innerWidth - 19)
            replyContentFrames = [
                CGRect(x: 11, y: 4, width: labelWidth, height: authorHeight),
                CGRect(x: 11, y: 6 + authorHeight, width: labelWidth, height: previewHeight)
            ]
            if p.title == nil { height += 8 }
            frames[.reply] = CGRect(x: bubbleX + inset, y: bubbleY + height, width: innerWidth, height: replyHeight)
            height += replyHeight + 6
        }
        var mediaFrames: [CGRect] = []
        if sticker {
            let dimensions = row.entry.remoteMessage?.sticker?.media
            let w = CGFloat(dimensions?.width ?? 0)
            let h = CGFloat(dimensions?.height ?? 0)
            let ratio = w.isFinite && h.isFinite && w > 0 && h > 0 ? w / h : 1
            let mediaWidth = min(b, 200)
            let mediaHeight = pixel(min(mediaWidth / ratio, mediaWidth), e)
            frames[.media] = CGRect(x: bubbleX + (row.isOutgoing ? b - mediaWidth : 0), y: bubbleY + height, width: mediaWidth, height: mediaHeight)
            height += mediaHeight
        } else if let preferredMedia {
            var mediaHeight: CGFloat
            if mediaCount > 1 {
                if !local.isEmpty, let gallery = BubbleMediaLayout.gallery(for: local, resolvedWidth: b) {
                    mediaHeight = gallery.size.height
                    mediaFrames = gallery.cells.map(\.frame)
                } else if let gallery = BubbleMediaLayout.gallery(for: remote, resolvedWidth: b) {
                    mediaHeight = gallery.size.height
                    mediaFrames = gallery.cells.map(\.frame)
                } else { mediaHeight = 0 }
            } else { mediaHeight = min(preferredMedia.height, min(560, b * 4 / 3)) }
            mediaHeight = pixel(mediaHeight, e)
            if mediaHeight > 0 {
                frames[.media] = CGRect(x: bubbleX, y: bubbleY + height, width: b, height: mediaHeight)
                mediaFrames = mediaFrames.map { rounded($0, e) }
                height += mediaHeight
            }
        }
        var geometry: MessageTextGeometry?
        if hasBody {
            height += hasMedia ? 4 : p.reply == nil && p.title == nil ? 8 : 0
            geometry = textMeasurer.geometry(for: innerWidth)
            frames[.text] = CGRect(x: bubbleX + inset, y: bubbleY + height, width: innerWidth, height: geometry!.size.height)
            height += geometry!.size.height
            if !hasMedia { height += 8 }
        } else if let label = p.standaloneText {
            if p.title == nil && p.reply == nil { height += 8 }
            let labelWidth = max(0, innerWidth - displayedSymbolSize.width - standaloneGap)
            let labelSize = labelWidth >= 1 ? wrappedSize(label, font: labelFont, width: labelWidth) : .zero
            frames[.standalone] = CGRect(x: bubbleX + inset, y: bubbleY + height, width: innerWidth, height: pixel(max(labelSize.height, displayedSymbolSize.height), e))
            height += frames[.standalone]!.height + 8
        }
        if let metadata {
            if p.metadataIsOverlay, let media = frames[.media] {
                let outerInset = min(sticker ? 4 : 6, media.width / 2)
                let pillPadding = min(6, max(0, (media.width - 2 * outerInset) / 2))
                let size = scaled(metadata.size, width: max(0, media.width - 2 * (outerInset + pillPadding)))
                let pillHeight = min(media.height, size.height + 4)
                let pillWidth = min(media.width, size.width + 2 * pillPadding)
                frames[.metadata] = CGRect(x: media.maxX - outerInset - pillWidth, y: max(media.minY, media.maxY - outerInset - pillHeight), width: pillWidth, height: pillHeight)
            } else if hasMedia || !hasBody {
                if !hasMedia && p.reply == nil && p.title == nil { height += 8 }
                let size = scaled(metadata.size, width: innerWidth)
                frames[.metadata] = CGRect(x: bubbleX + b - inset - size.width, y: bubbleY + height, width: size.width, height: size.height)
                height += size.height + 8
            }
        }
        var threadContentFrames: [CGRect] = []
        if let threadContent {
            let padding = min(12, b / 2)
            let available = max(0, b - 2 * padding)
            let symbol = scaled(threadContent.symbol, width: available)
            let gap = min(6, max(0, available - symbol.width))
            let chevron = scaled(threadContent.chevron, width: max(0, available - symbol.width - gap))
            let trailingGap = min(12, max(0, available - symbol.width - gap - chevron.width))
            let labelWidth: CGFloat = max(0, available - symbol.width - gap - chevron.width - trailingGap)
            let footerHeight = pixel(max(40, max(symbol.height, threadContent.label.height, chevron.height) + 20), e)
            threadContentFrames = [
                CGRect(x: padding, y: (footerHeight - symbol.height) / 2, width: symbol.width, height: symbol.height),
                CGRect(x: padding + symbol.width + gap, y: (footerHeight - threadContent.label.height) / 2,
                       width: labelWidth, height: threadContent.label.height),
                CGRect(x: b - padding - chevron.width, y: (footerHeight - chevron.height) / 2,
                       width: chevron.width, height: chevron.height)
            ].map { rounded($0, e) }
            frames[.thread] = CGRect(x: bubbleX, y: bubbleY + height, width: b, height: footerHeight)
            height += footerHeight
        }
        frames[.bubble] = CGRect(x: bubbleX, y: bubbleY, width: b, height: height)
        let mainBottom = max(4 + e.avatarSize, bubbleY + height)
        if row.groupPosition == .single || row.groupPosition == .last {
            frames[.avatar] = CGRect(x: row.isOutgoing ? e.timelineWidth - 12 - e.avatarSize : 12, y: mainBottom - e.avatarSize, width: e.avatarSize, height: e.avatarSize)
        }
        y = mainBottom
        var reactionFrames: [CGRect] = []
        var reactionContentFrames: [[CGRect]] = []
        if !deleted, let reactions = row.entry.remoteMessage?.reactions, !reactions.isEmpty {
            let result = reactionGeometry(reactions.sorted(by: TimelineRowPresentation.reactionOrder), width: c, outgoing: row.isOutgoing, environment: e)
            y += 8
            frames[.reactions] = CGRect(x: centralX, y: y, width: c, height: result.size.height)
            reactionFrames = result.frames
            reactionContentFrames = result.contentFrames
            y += result.size.height + 8
        }
        return .init(size: CGSize(width: e.timelineWidth, height: pixel(y + 4, e)), frames: frames.mapValues { rounded($0, e) }, textGeometry: geometry, mediaFrames: mediaFrames, reactionFrames: reactionFrames, reactionContentFrames: reactionContentFrames, titleFrames: titleFrames, replyContentFrames: replyContentFrames, standaloneSymbolSize: displayedSymbolSize, standaloneLabelGap: standaloneGap, threadContentFrames: threadContentFrames)
    }

    private func titleGeometry(_ title: TitleContent, width: CGFloat, environment e: TimelineLayoutEnvironment, fillsWidth: Bool = false) -> (size: CGSize, frames: [CGRect]) {
        let name = nativeSize(title.name, size: e.captionSize, weight: .semibold)
        let group = title.groupName.map { nativeSize($0, size: e.captionSize) }
        let gender = title.genderGlyph.map { nativeSize($0, size: e.captionSize) }
        let natural = pixel(name.width, e) + (group.map { pixel($0.width + 10, e) + 8 } ?? 0) + (gender.map { pixel($0.width, e) + 8 } ?? 0)
        let w = fillsWidth ? width : min(width, natural)
        let h = pixel(max(name.height, group?.height ?? 0, gender?.height ?? 0), e)
        // The bubble already grows to the complete header's natural width.
        // Only the column limit may compress it: name first, gender, then tag.
        let nameMinimum = min(w, pixel(name.width, e))
        let genderNatural = gender.map { pixel($0.width, e) } ?? 0
        let genderWidth = genderNatural > 0 && w - nameMinimum >= genderNatural + 8 ? genderNatural : 0
        let genderGap: CGFloat = genderWidth > 0 ? 8 : 0
        let groupAvailable = max(0, w - nameMinimum - genderWidth - genderGap - 8)
        let groupNatural = group.map { pixel($0.width + 10, e) } ?? 0
        var groupWidth = min(groupAvailable, groupNatural)
        if groupWidth > 0, groupWidth < groupNatural,
           groupWidth <= pixel(nativeSize("…", size: e.captionSize).width + 10, e) {
            groupWidth = 0
        }
        let groupGap: CGFloat = groupWidth > 0 ? 8 : 0
        let nameWidth = max(0, w - genderWidth - genderGap - groupWidth - groupGap)
        return (CGSize(width: w, height: h), [CGRect(x: 0, y: 0, width: nameWidth, height: h), CGRect(x: nameWidth + groupGap, y: 0, width: groupWidth, height: h), CGRect(x: w - genderWidth, y: 0, width: genderWidth, height: h)])
    }

    private func reactionGeometry(_ reactions: [ReactionSummary], width: CGFloat, outgoing: Bool, environment e: TimelineLayoutEnvironment) -> (size: CGSize, frames: [CGRect], contentFrames: [[CGRect]]) {
        var lines: [[CGSize]] = [[]]
        var used: CGFloat = 0
        var contentFrames: [[CGRect]] = []
        for reaction in reactions {
            let emoji = nativeSize(reaction.emoji, size: 18.5)
            var w = emoji.width + 7.5
            var h = max(26, emoji.height)
            var countSize: CGSize = .zero
            let reactors = min(5, reaction.reactors?.count ?? 0)
            if reactors > 0 {
                w += 2 + CGFloat(reactors) * 23 - CGFloat(reactors - 1) * 9
                if reaction.count > 5 {
                    let label = nativeSize("+\(reaction.count - 5)", size: 11)
                    countSize = label
                    w += 2 + label.width + 4
                    h = max(h, label.height)
                }
            } else if reaction.count > 1 {
                let label = nativeSize("\(reaction.count)", size: 12)
                countSize = label
                w += 2 + label.width + 6
                h = max(h, label.height)
            }
            let size = CGSize(width: min(width, pixel(w, e)), height: pixel(h, e))
            let emojiFrame = CGRect(x: 6, y: (size.height - emoji.height) / 2, width: emoji.width, height: emoji.height)
            let avatarX = emojiFrame.maxX + 2
            let countX = reactors > 0 ? avatarX + CGFloat(reactors) * 23 - CGFloat(reactors - 1) * 9 + 2 : avatarX
            let countFrame = countSize == .zero ? CGRect.zero : CGRect(x: countX, y: (size.height - countSize.height) / 2, width: countSize.width, height: countSize.height)
            var content = [emojiFrame, countFrame]
            for index in 0..<reactors {
                content.append(CGRect(x: avatarX + CGFloat(index) * 14, y: (size.height - 23) / 2, width: 23, height: 23))
            }
            contentFrames.append(content)
            if used > 0 && used + 4 + size.width > width { lines.append([]); used = 0 }
            lines[lines.count - 1].append(size)
            used += (used > 0 ? 4 : 0) + size.width
        }
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for line in lines {
            let w = line.reduce(0) { $0 + $1.width } + CGFloat(max(0, line.count - 1)) * 4
            var x = outgoing ? width - w : 0
            for size in line { frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size)); x += size.width + 4 }
            y += (line.map(\.height).max() ?? 0) + 4
        }
        return (CGSize(width: width, height: max(0, y - 4)), frames, contentFrames)
    }

    private func standalone(_ p: TimelineRowPresentation, environment e: TimelineLayoutEnvironment) -> TimelineRowLayout {
        let text = p.standaloneText ?? ""
        let frame: CGRect
        let height: CGFloat
        switch p.row {
        case .message(let row):
            let width = max(0, min(520, e.timelineWidth - 32))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            paragraph.alignment = .center
            let attributed = NSMutableAttributedString(string: "", attributes: [.font: BubbleNativeFont.systemFont(ofSize: 13), .paragraphStyle: paragraph])
            if let name = row.entry.remoteMessage?.sender.name, !name.isEmpty {
                attributed.append(NSAttributedString(string: name + " ", attributes: [.font: BubbleNativeFont.systemFont(ofSize: 13, weight: .semibold), .paragraphStyle: paragraph]))
            }
            attributed.append(NSAttributedString(string: text, attributes: [.font: BubbleNativeFont.systemFont(ofSize: 13), .paragraphStyle: paragraph]))
            let size = attributed.boundingRect(with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
            frame = CGRect(x: (e.timelineWidth - width) / 2, y: 8, width: width, height: pixel(size.height, e))
            height = frame.maxY + 8
        case .dateSeparator:
            let horizontal = ChahuaTheme.Spacing.medium
            let vertical = ChahuaTheme.Spacing.xSmall
            let size = wrappedSize(text, font: .systemFont(ofSize: e.captionSize), width: max(1, e.timelineWidth - 2 * horizontal))
            let width = min(e.timelineWidth, pixel(size.width + 2 * horizontal, e))
            frame = CGRect(x: (e.timelineWidth - width) / 2, y: ChahuaTheme.Spacing.medium, width: width, height: pixel(size.height + 2 * vertical, e))
            height = frame.maxY + ChahuaTheme.Spacing.medium
        case .unreadSeparator:
            let inset = min(ChahuaTheme.Spacing.medium, e.timelineWidth / 2)
            let size = wrappedSize(text, font: .systemFont(ofSize: e.captionSize), width: max(1, e.timelineWidth - 2 * inset))
            frame = CGRect(x: inset, y: ChahuaTheme.Spacing.medium, width: e.timelineWidth - 2 * inset, height: pixel(size.height, e))
            height = frame.maxY + ChahuaTheme.Spacing.medium
        }
        return .init(size: CGSize(width: e.timelineWidth, height: pixel(height, e)), frames: [.standalone: rounded(frame, e)], textGeometry: nil, mediaFrames: [], reactionFrames: [])
    }

    private func singleLineSize(_ string: String, size: CGFloat, weight: BubbleNativeFont.Weight = .regular) -> CGSize {
        // Without usesLineFragmentOrigin, native drawing measures one line,
        // matching the quote labels' lineLimit(1), including embedded newlines.
        NSAttributedString(string: string.isEmpty ? " " : string, attributes: [.font: BubbleNativeFont.systemFont(ofSize: size, weight: weight)])
            .boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude), options: [.usesFontLeading], context: nil).size
    }

    private func nativeSize(_ string: String, size: CGFloat, weight: BubbleNativeFont.Weight = .regular) -> CGSize {
        nativeSize(string.isEmpty ? " " : string, font: .systemFont(ofSize: size, weight: weight))
    }
    private func nativeSize(_ string: String, font: BubbleNativeFont) -> CGSize {
        NSAttributedString(string: string, attributes: [.font: font]).size()
    }
    private func wrappedSize(_ string: String, font: BubbleNativeFont, width: CGFloat) -> CGSize {
        NSAttributedString(string: string, attributes: [.font: font]).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).size
    }
    private func scaled(_ size: CGSize, width: CGFloat) -> CGSize {
        let scale = size.width > 0 ? min(1, max(0, width) / size.width) : 1
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
    private func pixel(_ value: CGFloat, _ e: TimelineLayoutEnvironment) -> CGFloat {
        let scale = e.displayScale.isFinite && e.displayScale > 0 ? e.displayScale : 1
        return ceil(value * scale) / scale
    }
    private func rounded(_ frame: CGRect, _ e: TimelineLayoutEnvironment) -> CGRect {
        let x = pixel(frame.minX, e), y = pixel(frame.minY, e)
        return CGRect(x: x, y: y, width: max(0, pixel(frame.maxX, e) - x), height: max(0, pixel(frame.maxY, e) - y))
    }
}
