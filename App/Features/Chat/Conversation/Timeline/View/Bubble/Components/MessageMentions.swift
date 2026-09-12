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

}
