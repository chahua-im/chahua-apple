import Foundation

struct ComposerMentionQuery: Equatable {
    let query: String
    let range: NSRange
}

enum ComposerMentionKey {
    case up, down, accept, dismiss
}

/// Each insertion owns an identity, even when two members have identical names.
/// Undo metadata retains these objects, never reconstructing IDs from names.
final class ComposerMentionSpan: NSObject, NSCopying {
    let uid: Int32
    let text: String
    var isValid = true

    init(uid: Int32, label: String) {
        self.uid = uid
        text = "@" + label
    }

    func copy(with zone: NSZone? = nil) -> Any { self }
}

enum ComposerMentionText {
    static let attribute = NSAttributedString.Key("ChahuaComposerMention")

    static func expand(_ wireText: String, names: [Int32: String]) -> NSAttributedString {
        let text = wireText as NSString
        let result = NSMutableAttributedString(string: "")
        var cursor = 0
        for match in MessageMentions.pattern.matches(
            in: wireText, range: NSRange(location: 0, length: text.length))
        {
            guard let uid = Int32(text.substring(with: match.range(at: 1))) else { continue }
            result.append(
                NSAttributedString(
                    string: text.substring(
                        with: NSRange(location: cursor, length: match.range.location - cursor))))
            result.append(mention(uid: uid, label: names[uid] ?? "User \(uid)"))
            cursor = NSMaxRange(match.range)
        }
        result.append(NSAttributedString(string: text.substring(from: cursor)))
        return result
    }

    static func mention(uid: Int32, label: String) -> NSAttributedString {
        let span = ComposerMentionSpan(uid: uid, label: label)
        return NSAttributedString(string: span.text, attributes: [attribute: span])
    }

    static func spans(in text: NSAttributedString) -> [(ComposerMentionSpan, NSRange)] {
        var spans: [(ComposerMentionSpan, NSRange)] = []
        text.enumerateAttribute(attribute, in: NSRange(location: 0, length: text.length)) {
            value, range, _ in
            if let span = value as? ComposerMentionSpan, span.isValid,
                (text.string as NSString).substring(with: range) == span.text
            {
                spans.append((span, range))
            }
        }
        return spans
    }

    static func wireText(_ text: NSAttributedString) -> String {
        let result = NSMutableString(string: text.string)
        for (span, range) in spans(in: text).reversed() {
            result.replaceCharacters(in: range, with: "@[uid:\(span.uid)]")
        }
        return result as String
    }

    static func query(in text: NSAttributedString, selection: NSRange) -> ComposerMentionQuery? {
        guard selection.length == 0, selection.location <= text.length else { return nil }
        let caret = selection.location
        guard
            !spans(in: text).contains(where: { _, range in
                caret > range.location && caret <= NSMaxRange(range)
            })
        else { return nil }
        let string = text.string as NSString
        var start = caret
        while start > 0 {
            let range = string.rangeOfComposedCharacterSequence(at: start - 1)
            let character = string.substring(with: range)
            if character.unicodeScalars.contains(
                where: CharacterSet.whitespacesAndNewlines.contains)
            {
                break
            }
            start = range.location
        }
        guard start < caret, string.substring(with: NSRange(location: start, length: 1)) == "@"
        else { return nil }
        let range = NSRange(location: start, length: caret - start)
        return ComposerMentionQuery(
            query: string.substring(with: NSRange(location: start + 1, length: range.length - 1)),
            range: range)
    }
}
