import ChahuaAPI
import Foundation

enum MessageMentions {
    static let pattern = try! NSRegularExpression(pattern: #"@\[uid:(\d+)\]"#)

    static func names(in mentions: [MentionInfo]) -> [Int32: String] {
        var names: [Int32: String] = [:]
        for mention in mentions {
            if let name = mention.username, !name.isEmpty { names[mention.uid] = name }
        }
        return names
    }

    /// Copy keeps the source formatting and links, unlike a flattened preview.
    /// Share the editor's token grammar and the displayed missing-name fallback.
    static func plainText(_ text: String, mentions: [MentionInfo]) -> String {
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        let names = names(in: mentions)
        let source = text as NSString
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard let uid = Int32(source.substring(with: match.range(at: 1))) else { continue }
            result.replaceCharacters(in: match.range, with: "@\(names[uid] ?? "User \(uid)")")
        }
        return result as String
    }

}
