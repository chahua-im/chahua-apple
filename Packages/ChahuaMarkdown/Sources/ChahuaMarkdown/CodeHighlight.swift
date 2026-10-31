import Foundation
import JavaScriptCore

/// A UTF-16 source range classified by highlight.js scope. Ancestors precede descendants.
public struct MarkdownCodeSpan: Equatable, Sendable {
    public let range: NSRange
    public let kind: String

    public init(range: NSRange, kind: String) {
        self.range = range
        self.kind = kind
    }
}

/// Uses the same pinned highlight.js grammars as the PWA, without a web view or HTML rendering.
public enum MarkdownCodeHighlight {
    private static let engine = HighlightEngine()

    public static func supports(language: String?) -> Bool {
        guard let language, isValid(language: language) else { return false }
        return engine.supports(language: language)
    }

    public static func spans(code: String, language: String?) -> [MarkdownCodeSpan] {
        guard let language, isValid(language: language) else { return [] }
        return engine.spans(code: code, language: language)
    }

    private static func isValid(language: String) -> Bool {
        !language.isEmpty
            && language.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 95 || $0 == 43 || $0 == 45
            }
    }
}

// JavaScriptCore contexts are serialized, including creation, evaluation and value access.
// User code is passed as a string argument; it is never evaluated as JavaScript.
private final class HighlightEngine: @unchecked Sendable {
    private let lock = NSLock()
    private struct Key: Hashable {
        let code: String
        let language: String
    }

    private var cache: [Key: [MarkdownCodeSpan]] = [:]
    private var cacheCost = 0
    private let maximumCacheCost = 512 * 1024
    private var context: JSContext?
    private var supportedLanguages: [String: Bool] = [:]

    func supports(language: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let supported = supportedLanguages[language] { return supported }
        let context = self.context ?? makeContext()
        self.context = context
        context.exception = nil
        let result = context.objectForKeyedSubscript("chahuaSupportsLanguage")!
            .call(withArguments: [language])
        precondition(context.exception == nil, "Bundled Markdown language lookup failed")
        let supported = result?.toBool() ?? false
        // Bound user-provided aliases just as code token caching is bounded.
        if supportedLanguages.count >= 128 { supportedLanguages.removeAll(keepingCapacity: true) }
        supportedLanguages[language] = supported
        return supported
    }

    func spans(code: String, language: String) -> [MarkdownCodeSpan] {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(code: code, language: language)
        if let cached = cache[key] { return cached }
        let context = self.context ?? makeContext()
        self.context = context
        context.exception = nil
        let result = context.objectForKeyedSubscript("chahuaHighlight")!
            .call(withArguments: [code, language])
        precondition(context.exception == nil, "Bundled Markdown highlighter failed")
        guard let tokens = result?.toArray() as? [[String: Any]] else {
            preconditionFailure("Bundled Markdown highlighter returned an invalid token stream")
        }
        let spans = tokens.map { token in
            let location = (token["location"] as! NSNumber).intValue
            let length = (token["length"] as! NSNumber).intValue
            return MarkdownCodeSpan(
                range: NSRange(location: location, length: length), kind: token["kind"] as! String)
        }
        let cost = code.utf16.count * 2 + spans.count * MemoryLayout<MarkdownCodeSpan>.stride
        if cost <= maximumCacheCost {
            if cache.count >= 128 || cacheCost + cost > maximumCacheCost {
                cache.removeAll(keepingCapacity: true)
                cacheCost = 0
            }
            cache[key] = spans
            cacheCost += cost
        }
        return spans
    }

    private func makeContext() -> JSContext {
        guard let context = JSContext(),
            let source = Bundle.module.url(forResource: "highlight", withExtension: "js")
        else { preconditionFailure("Bundled Markdown highlighter is unavailable") }
        do {
            let script = try String(contentsOf: source, encoding: .utf8)
            context.evaluateScript(script, withSourceURL: source)
        } catch {
            preconditionFailure("Cannot read bundled Markdown highlighter: \(error)")
        }
        precondition(context.exception == nil, "Cannot initialize bundled Markdown highlighter")
        return context
    }
}
