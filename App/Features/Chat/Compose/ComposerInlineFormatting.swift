import Foundation
import SwiftUI

/// Wire markers wrap each selected paragraph, leaving edge whitespace and blank lines untouched.
enum ComposerInlineFormat {
    case bold, italic
    private static let separators = try! NSRegularExpression(pattern: "\\r?\\n(?:[ \\t]*\\r?\\n)+")

    var marker: String { self == .bold ? "**" : "__" }

    func wrapping(_ text: NSAttributedString, selection: NSRange) -> NSAttributedString? {
        guard selection.length > 0, selection.location != NSNotFound,
            NSMaxRange(selection) <= text.length
        else { return nil }
        let selected = (text.string as NSString).substring(with: selection) as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        var insertions: [Int] = []
        var start = 0
        func appendParagraph(endingAt end: Int) {
            let part = selected.substring(with: NSRange(location: start, length: end - start))
            let body = part.trimmingCharacters(in: whitespace)
            guard !body.isEmpty else { return }
            let leading = (part as NSString).rangeOfCharacter(from: whitespace.inverted).location
            let trailing = NSMaxRange(
                (part as NSString).rangeOfCharacter(
                    from: whitespace.inverted, options: .backwards))
            insertions.append(selection.location + start + leading)
            insertions.append(selection.location + start + trailing)
        }
        for separator in Self.separators.matches(
            in: selected as String, range: NSRange(location: 0, length: selected.length))
        {
            appendParagraph(endingAt: separator.range.location)
            start = NSMaxRange(separator.range)
        }
        appendParagraph(endingAt: selected.length)
        guard !insertions.isEmpty else { return nil }
        let result = NSMutableAttributedString(string: text.string)
        for offset in insertions.reversed() {
            result.insert(NSAttributedString(string: marker), at: offset)
        }
        // Identity survives marker insertion around a mention, but never insertion inside its label.
        for (span, range) in ComposerMentionText.spans(in: text) {
            guard !insertions.contains(where: { $0 > range.location && $0 < NSMaxRange(range) })
            else { continue }
            let before = insertions.filter { $0 <= range.location }.count * 2
            let within = insertions.filter { $0 < NSMaxRange(range) }.count * 2
            let mapped = NSRange(
                location: range.location + before, length: range.length + within - before)
            result.addAttribute(ComposerMentionText.attribute, value: span, range: mapped)
        }
        return result
    }
}

struct ComposerFormattingShortcuts: ViewModifier {
    let input: ComposerInputState

    func body(content: Content) -> some View {
        #if os(iOS)
            content.onKeyPress(keys: ["b", "i"]) { press in
                guard !press.modifiers.contains(.option),
                    !press.modifiers.intersection([.command, .control]).isEmpty
                else { return .ignored }
                // Consume the shortcut even for an empty/marked selection; never invoke rich-text formatting.
                _ = input.nativeInput?.formatSelection(press.key == "b" ? .bold : .italic)
                return .handled
            }
        #else
            content
        #endif
    }
}
