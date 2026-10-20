import Foundation

/// The chat dialect deliberately does not interpret display names as Markdown.
public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case strikethrough([MarkdownInline])
    case spoiler([MarkdownInline])
    case code(String)
    case link(destination: String, children: [MarkdownInline])
    case mention(Int32)
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case codeBlock(language: String?, code: String)
    case list(orderedStart: Int?, items: [[MarkdownBlock]])
}

public struct MarkdownDocument: Equatable, Sendable {
    public let blocks: [MarkdownBlock]

    public init(parsing source: String) {
        blocks = MarkdownParser.parse(source)
    }

    /// A semantic single-line projection, including spoilers and list prefixes.
    public var summary: [MarkdownInline] {
        Self.summarize(blocks)
    }

    private static func summarize(_ blocks: [MarkdownBlock]) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        func add(_ content: [MarkdownInline]) {
            guard !content.isEmpty else { return }
            if !result.isEmpty { result.append(.text(" ")) }
            result.append(contentsOf: content)
        }
        for block in blocks {
            switch block {
            case .paragraph(let content):
                add(singleLine(content))
            case .codeBlock(_, let code):
                let text = code.replacingOccurrences(
                    of: "\\s*\\n+\\s*", with: " ", options: .regularExpression
                )
                .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { add([.code(text)]) }
            case .list(let start, let items):
                var number = max(start ?? 1, 1)
                for item in items {
                    var content: [MarkdownInline] = [.text(start == nil ? "• " : "\(number). ")]
                    content.append(contentsOf: summarize(item))
                    add(content)
                    number += 1
                }
            }
        }
        return coalescingText(result)
    }

    private static func singleLine(_ content: [MarkdownInline]) -> [MarkdownInline] {
        content.map { node in
            switch node {
            case .text(let text):
                return .text(
                    text.replacingOccurrences(
                        of: "[\\r\\n\\u2028\\u2029]+", with: " ", options: .regularExpression))
            case .strong(let children): return .strong(singleLine(children))
            case .emphasis(let children): return .emphasis(singleLine(children))
            case .strikethrough(let children): return .strikethrough(singleLine(children))
            case .spoiler(let children): return .spoiler(singleLine(children))
            case .link(let destination, let children):
                return .link(destination: destination, children: singleLine(children))
            case .code: return node
            case .mention: return node
            }
        }
    }
}

internal func coalescingText(_ nodes: [MarkdownInline]) -> [MarkdownInline] {
    var result: [MarkdownInline] = []
    var pending = ""
    for node in nodes {
        if case .text(let text) = node {
            pending += text
        } else {
            if !pending.isEmpty {
                result.append(.text(pending))
                pending = ""
            }
            result.append(node)
        }
    }
    if !pending.isEmpty { result.append(.text(pending)) }
    return result
}
