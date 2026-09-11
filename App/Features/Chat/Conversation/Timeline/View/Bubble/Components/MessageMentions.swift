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

    static func expanding(in text: String, mentions: [MentionInfo]) -> String {
        let source = text as NSString
        let result = NSMutableString(string: text)
        let names = names(in: mentions)
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).reversed() {
            let rawID = source.substring(with: match.range(at: 1))
            let name = Int32(rawID).flatMap { names[$0] } ?? "User \(rawID)"
            result.replaceCharacters(in: match.range, with: "@\(name)")
        }
        return result as String
    }
}
