import Foundation

internal enum InlineParser {
    typealias Scalar = Unicode.Scalar

    private struct Delimiter {
        let marker: Scalar
        let canOpen: Bool
        let canClose: Bool
        var end: Int?
    }

    private enum Token {
        case node(MarkdownInline)
        case label([MarkdownInline])
        case escaped(String)
        case delimiter(Delimiter)
    }

    static func parse(_ source: [Scalar], hasMarkup: inout Bool) -> [MarkdownInline] {
        let normalized = normalizing(source)
        var start = 0
        var end = normalized.count
        // Reflow happens before the PWA block parser trims its paragraph.
        while start < end, isWhitespace(normalized[start]) { start += 1 }
        while end > start, isWhitespace(normalized[end - 1]) { end -= 1 }
        return parse(
            Array(normalized[start..<end]), allowLinks: true, depth: 0, hasMarkup: &hasMarkup)
    }

    private static func parse(
        _ source: [Scalar], allowLinks: Bool, depth: Int, hasMarkup: inout Bool
    ) -> [MarkdownInline] {
        guard depth < 100 else { return [.text(scalarString(source))] }
        // Explicit schemes have priority over emphasis; fuzzy domains are
        // linkified in text tokens after delimiter pairing, as in markdown-it.
        let automaticLinks = allowLinks ? AutomaticLinks.matches(source, explicitOnly: true) : [:]
        var tokens: [Token] = []
        var pending: [Scalar] = []
        var position = 0
        func flush() {
            if !pending.isEmpty {
                tokens.append(.node(.text(scalarString(pending))))
                pending.removeAll(keepingCapacity: true)
            }
        }
        while position < source.count {
            let scalar = source[position]
            if scalar == "\n" {
                while pending.last == " " || pending.last == "\t" { pending.removeLast() }
                pending.append(scalar)
                position += 1
                while position < source.count, source[position] == " " || source[position] == "\t" {
                    position += 1
                }
                continue
            }
            if scalar == "\\", position + 1 < source.count {
                let next = source[position + 1]
                // The PWA extracts mention widgets before Markdown escaping.
                if next == "@", mention(source, at: position + 1) != nil {
                    pending.append(scalar)
                    position += 1
                    continue
                }
                if isEscapable(next) || next == "\n" {
                    if next == "\n" {
                        pending.append(next)
                    } else {
                        flush()
                        tokens.append(.escaped(String(next)))
                    }
                    position += 2
                    if next == "\n" {
                        while position < source.count,
                            source[position] == " " || source[position] == "\t"
                        { position += 1 }
                    }
                    continue
                }
            }
            if scalar == "`" {
                let end = runEnd(source, from: position)
                if let close = codeClose(source, from: end, count: end - position) {
                    hasMarkup = true
                    flush()
                    var code = source[end..<close].map { $0 == "\n" ? (" " as Scalar) : $0 }
                    if code.count >= 2, code.first == " ", code.last == " ",
                        code.contains(where: { $0 != " " })
                    {
                        code.removeLast()
                        code.removeFirst()
                    }
                    tokens.append(.node(.code(scalarString(code))))
                    position = close + end - position
                    continue
                }
                pending.append(contentsOf: source[position..<end])
                position = end
                continue
            }
            if scalar == "@", let mention = mention(source, at: position) {
                flush()
                tokens.append(.node(.mention(mention.uid)))
                position = mention.end
                continue
            }
            // Guard the opening bracket, not the rest of the text: other supported
            // markup inside an unsupported image macro behaves exactly like plain text.
            if scalar == "!", position + 1 < source.count, source[position + 1] == "[" {
                pending.append("!")
                pending.append("[")
                position += 2
                continue
            }
            if allowLinks, scalar == "[", let link = labelledLink(source, at: position) {
                flush()
                hasMarkup = true
                let children = parse(
                    Array(source[(position + 1)..<link.labelEnd]), allowLinks: false,
                    depth: depth + 1, hasMarkup: &hasMarkup)
                if safeHTTP(link.destination) {
                    tokens.append(
                        .node(
                            .link(destination: normalizedURL(link.destination), children: children))
                    )
                } else {
                    tokens.append(.label(children))
                }
                position = link.end
                continue
            }
            if let link = automaticLinks[position] {
                hasMarkup = true
                flush()
                tokens.append(
                    .node(
                        .link(
                            destination: normalizedURL(link.destination),
                            children: [.text(link.text)])))
                position = link.end
                continue
            }
            if scalar == "*" || scalar == "_" || scalar == "~" || scalar == "|" {
                let end = runEnd(source, from: position)
                let length = end - position
                if length >= 2 && (scalar != "*" || length == 2) {
                    flush()
                    let previous = position > 0 ? source[position - 1] : nil
                    let next = end < source.count ? source[end] : nil
                    let left =
                        !isWhitespace(next)
                        && (!isPunctuation(next) || isWhitespace(previous)
                            || isPunctuation(previous))
                    let right =
                        !isWhitespace(previous)
                        && (!isPunctuation(previous) || isWhitespace(next) || isPunctuation(next))
                    if length % 2 != 0 { tokens.append(.node(.text(String(scalar)))) }
                    for _ in 0..<(length / 2) {
                        tokens.append(
                            .delimiter(Delimiter(marker: scalar, canOpen: left, canClose: right)))
                    }
                } else {
                    pending.append(contentsOf: source[position..<end])
                }
                position = end
                continue
            }
            pending.append(scalar)
            position += 1
        }
        flush()
        balance(&tokens)
        if tokens.contains(where: { token in
            if case .delimiter(let delimiter) = token { return delimiter.end != nil }
            return false
        }) {
            hasMarkup = true
        }
        return render(tokens, range: tokens.indices, allowLinks: allowLinks, hasMarkup: &hasMarkup)
    }

    static func hasEscapedPunctuation(_ source: String) -> Bool {
        var previous: Scalar?
        for scalar in source.unicodeScalars {
            if previous == "\\", isEscapable(scalar) { return true }
            previous = scalar
        }
        return false
    }

    /// The PWA's legacy path preserves all source text and only restores mentions.
    static func plain(_ source: String) -> [MarkdownInline] {
        let scalars = Array(source.unicodeScalars)
        var result: [MarkdownInline] = []
        var start = 0
        var index = 0
        while index < scalars.count {
            if scalars[index] == "@", let match = mention(scalars, at: index) {
                if start < index { result.append(.text(scalarString(scalars[start..<index]))) }
                result.append(.mention(match.uid))
                index = match.end
                start = index
            } else {
                index += 1
            }
        }
        if start < scalars.count { result.append(.text(scalarString(scalars[start...]))) }
        return result
    }

    private static func balance(_ tokens: inout [Token]) {
        var open: [Int] = []
        for index in tokens.indices {
            guard case .delimiter(let current) = tokens[index] else { continue }
            if current.canClose,
                let match = open.lastIndex(where: { candidate in
                    guard case .delimiter(let previous) = tokens[candidate] else { return false }
                    return previous.marker == current.marker
                })
            {
                let opener = open[match]
                if case .delimiter(var delimiter) = tokens[opener] {
                    delimiter.end = index
                    tokens[opener] = .delimiter(delimiter)
                }
                // Crossing pairs are not valid nested containers.
                open.removeSubrange(match...)
            } else if current.canOpen {
                open.append(index)
            }
        }
        // The stock double-marker rules move an odd closing underscore/tilde
        // outside the closing container (___x___ becomes _<em>x</em>_).
        var loneMarkers: [Int] = []
        var closing: Set<Int> = []
        for token in tokens {
            if case .delimiter(let delimiter) = token, let end = delimiter.end {
                closing.insert(end)
                if delimiter.marker == "_" || delimiter.marker == "~",
                    end > 0, case .node(.text(let text)) = tokens[end - 1],
                    text == String(delimiter.marker)
                {
                    loneMarkers.append(end - 1)
                }
            }
        }
        for lone in loneMarkers.reversed() {
            guard case .node(.text(let text)) = tokens[lone] else { continue }
            var end = lone + 1
            while end < tokens.count, closing.contains(end),
                case .delimiter(let delimiter) = tokens[end], text == String(delimiter.marker)
            {
                end += 1
            }
            guard end > lone + 1 else { continue }
            let literal = tokens[lone]
            for index in lone..<(end - 1) { tokens[index] = tokens[index + 1] }
            tokens[end - 1] = literal
            for index in tokens.indices {
                if case .delimiter(var delimiter) = tokens[index], let close = delimiter.end,
                    close > lone, close < end
                {
                    closing.remove(close)
                    delimiter.end = close - 1
                    tokens[index] = .delimiter(delimiter)
                }
            }
            for index in lone..<(end - 1) { closing.insert(index) }
        }
    }

    private static func render(
        _ tokens: [Token], range: Range<Int>, allowLinks: Bool, hasMarkup: inout Bool
    ) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var pending = ""
        var followsEscape = false
        func flushText(hasMarkup: inout Bool) {
            guard !pending.isEmpty else { return }
            if allowLinks {
                result.append(
                    contentsOf: linkifyingText(
                        pending, suppressInitialLink: followsEscape, hasMarkup: &hasMarkup))
            } else {
                result.append(.text(pending))
            }
            pending = ""
        }
        var index = range.lowerBound
        while index < range.upperBound {
            switch tokens[index] {
            case .node(let node):
                if case .text(let text) = node {
                    pending += text
                } else {
                    flushText(hasMarkup: &hasMarkup)
                    result.append(node)
                    followsEscape = false
                }
                index += 1
            case .label(let children):
                flushText(hasMarkup: &hasMarkup)
                result.append(contentsOf: children)
                followsEscape = false
                index += 1
            case .escaped(let text):
                // Like markdown-it's text_special, escaped punctuation is
                // joined only after linkification and protects the next token.
                flushText(hasMarkup: &hasMarkup)
                result.append(.text(text))
                followsEscape = true
                index += 1
            case .delimiter(let delimiter):
                if let end = delimiter.end, end < range.upperBound {
                    flushText(hasMarkup: &hasMarkup)
                    followsEscape = false
                    let children = render(
                        tokens, range: (index + 1)..<end, allowLinks: allowLinks,
                        hasMarkup: &hasMarkup)
                    switch delimiter.marker {
                    case "*": result.append(.strong(children))
                    case "_": result.append(.emphasis(children))
                    case "~": result.append(.strikethrough(children))
                    default: result.append(.spoiler(children))
                    }
                    index = end + 1
                } else {
                    // fragments_join merges unmatched markers into surrounding
                    // text before fuzzy links are recognized.
                    pending += String(repeating: String(delimiter.marker), count: 2)
                    index += 1
                }
            }
        }
        flushText(hasMarkup: &hasMarkup)
        return coalescingText(result)
    }

    private static func linkifyingText(
        _ text: String, suppressInitialLink: Bool, hasMarkup: inout Bool
    ) -> [MarkdownInline] {
        guard text.contains(".") || text.contains(":") else { return [.text(text)] }
        let scalars = Array(text.unicodeScalars)
        var links = AutomaticLinks.matches(scalars)
        if suppressInitialLink { links.removeValue(forKey: 0) }
        guard !links.isEmpty else { return [.text(text)] }
        hasMarkup = true
        var result: [MarkdownInline] = []
        var position = 0
        for start in links.keys.sorted() {
            guard let link = links[start] else { continue }
            if start > position { result.append(.text(scalarString(scalars[position..<start]))) }
            result.append(
                .link(destination: normalizedURL(link.destination), children: [.text(link.text)]))
            position = link.end
        }
        if position < scalars.count { result.append(.text(scalarString(scalars[position...]))) }
        return result
    }

    private static func mention(_ source: [Scalar], at start: Int) -> (uid: Int32, end: Int)? {
        guard matches(source, at: start, ascii: "@[uid:") else { return nil }
        var index = start + 6
        let digits = index
        var value: Int32 = 0
        while index < source.count, isDigit(source[index]) {
            let (multiplied, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            let (added, addOverflow) = multiplied.addingReportingOverflow(
                Int32(source[index].value - 48))
            guard !multiplyOverflow, !addOverflow else { return nil }
            value = added
            index += 1
        }
        guard index > digits, index < source.count, source[index] == "]" else { return nil }
        return (value, index + 1)
    }

    private static func runEnd(_ source: [Scalar], from start: Int) -> Int {
        var end = start + 1
        while end < source.count, source[end] == source[start] { end += 1 }
        return end
    }

    private static func codeClose(_ source: [Scalar], from start: Int, count: Int) -> Int? {
        var position = start
        while position < source.count {
            if source[position] != "`" {
                position += 1
                continue
            }
            let end = runEnd(source, from: position)
            if end - position == count { return position }
            position = end
        }
        return nil
    }

    /// PWA's length-preserving inner-space reflow. Code and escaped characters
    /// are masked first, and no pair is allowed to cross a physical line.
    private static func normalizing(_ source: [Scalar]) -> [Scalar] {
        var masked = Array(repeating: false, count: source.count)
        var index = 0
        while index < source.count {
            if source[index] == "\\", index + 1 < source.count {
                masked[index] = true
                masked[index + 1] = true
                index += 2
            } else if source[index] == "`" {
                let end = runEnd(source, from: index)
                if let close = codeClose(source, from: end, count: end - index) {
                    let closeEnd = close + end - index
                    for maskedIndex in index..<closeEnd { masked[maskedIndex] = true }
                    index = closeEnd
                } else {
                    index = end
                }
            } else {
                index += 1
            }
        }
        var open: [(marker: Scalar, start: Int)] = []
        var pairs: [(Int, Int)] = []
        index = 0
        while index < source.count {
            if source[index] == "\n" { open.removeAll(keepingCapacity: true) }
            let marker = source[index]
            guard !masked[index], marker == "*" || marker == "_" || marker == "~" else {
                index += 1
                continue
            }
            let end = runEnd(source, from: index)
            if end - index == 2 {
                if let match = open.firstIndex(where: { $0.marker == marker }) {
                    pairs.append((open[match].start, index))
                    open.removeSubrange(match...)
                } else {
                    open.append((marker, index))
                }
            }
            index = end
        }
        guard !pairs.isEmpty else { return source }
        var output = source
        for (start, end) in pairs.sorted(by: { $0.0 > $1.0 }) {
            guard end > start + 2 else { continue }
            var first = start + 2
            while first < end, output[first] == " " || output[first] == "\t" { first += 1 }
            var last = end
            while last > first, output[last - 1] == " " || output[last - 1] == "\t" { last -= 1 }
            guard first < last, first != start + 2 || last != end else { continue }
            let previous = start > 0 ? output[start - 1] : nil
            let next = end + 2 < output.count ? output[end + 2] : nil
            if previous.map(isDigit) == true || next.map(isDigit) == true { continue }
            if output[start] == "_",
                previous.map(isASCIIAlphaNumeric) == true || next.map(isASCIIAlphaNumeric) == true
            {
                continue
            }
            var replacement: [Scalar] = []
            replacement.reserveCapacity(end + 2 - start)
            replacement.append(contentsOf: output[(start + 2)..<first])
            replacement.append(output[start])
            replacement.append(output[start])
            replacement.append(contentsOf: output[first..<last])
            replacement.append(output[start])
            replacement.append(output[start])
            replacement.append(contentsOf: output[last..<end])
            output.replaceSubrange(start..<(end + 2), with: replacement)
        }
        return output
    }

    private static func labelledLink(_ source: [Scalar], at start: Int) -> (
        labelEnd: Int, destination: String, end: Int
    )? {
        var index = start + 1
        var nesting = 1
        while index < source.count {
            if source[index] == "\\", index + 1 < source.count {
                index += 2
                continue
            }
            if source[index] == "`" {
                let end = runEnd(source, from: index)
                if let close = codeClose(source, from: end, count: end - index) {
                    index = close + end - index
                    continue
                }
            }
            if source[index] == "[" { nesting += 1 }
            if source[index] == "]" {
                nesting -= 1
                if nesting == 0 { break }
            }
            index += 1
        }
        guard index + 1 < source.count, nesting == 0, source[index + 1] == "(" else { return nil }
        let labelEnd = index
        index += 2
        while index < source.count, isWhitespace(source[index]) { index += 1 }
        var destination: [Scalar] = []
        if index < source.count, source[index] == "<" {
            index += 1
            while index < source.count, source[index] != ">" {
                if source[index] == "\n" || source[index] == "<" { return nil }
                if source[index] == "\\", index + 1 < source.count, isEscapable(source[index + 1]) {
                    index += 1
                }
                destination.append(source[index])
                index += 1
            }
            guard index < source.count, source[index] == ">" else { return nil }
            index += 1
        } else {
            var parentheses = 0
            while index < source.count {
                let scalar = source[index]
                if isWhitespace(scalar) { break }
                if scalar.value < 32 { return nil }
                if scalar == "\\", index + 1 < source.count, isEscapable(source[index + 1]) {
                    destination.append(source[index + 1])
                    index += 2
                    continue
                }
                if scalar == "(" {
                    parentheses += 1
                    if parentheses > 32 { return nil }
                }
                if scalar == ")" {
                    if parentheses == 0 { break }
                    parentheses -= 1
                }
                destination.append(scalar)
                index += 1
            }
            guard parentheses == 0 else { return nil }
        }
        let afterDestination = index
        while index < source.count, isWhitespace(source[index]) { index += 1 }
        if index > afterDestination, index < source.count,
            source[index] == "\"" || source[index] == "'" || source[index] == "("
        {
            let closing: Scalar = source[index] == "(" ? ")" : source[index]
            index += 1
            while index < source.count, source[index] != closing {
                if source[index] == "\\", index + 1 < source.count {
                    index += 2
                } else {
                    index += 1
                }
            }
            guard index < source.count else { return nil }
            index += 1
            while index < source.count, isWhitespace(source[index]) { index += 1 }
        }
        guard index < source.count, source[index] == ")" else { return nil }
        let href = scalarString(destination)
        // markdown-it rejects these before constructing a link token at all.
        let scheme = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if scheme.hasPrefix("javascript:") || scheme.hasPrefix("vbscript:")
            || scheme.hasPrefix("file:") || scheme.hasPrefix("data:")
        {
            return nil
        }
        return (labelEnd, href, index + 1)
    }

    private static func safeHTTP(_ destination: String) -> Bool {
        let lower = destination.lowercased()
        return lower.hasPrefix("https://") || lower.hasPrefix("http://")
    }

    private static func normalizedURL(_ destination: String) -> String {
        URL(string: destination)?.absoluteString ?? destination
    }

    private static func matches(_ source: [Scalar], at start: Int, ascii: StaticString) -> Bool {
        ascii.withUTF8Buffer { bytes in
            guard source.count - start >= bytes.count else { return false }
            for offset in bytes.indices {
                let value = source[start + offset].value
                if value != UInt32(bytes[offset]) { return false }
            }
            return true
        }
    }

    private static func isEscapable(_ scalar: Scalar) -> Bool {
        (scalar.value >= 33 && scalar.value <= 47) || (scalar.value >= 58 && scalar.value <= 64)
            || (scalar.value >= 91 && scalar.value <= 96)
            || (scalar.value >= 123 && scalar.value <= 126)
    }

    private static func isWhitespace(_ scalar: Scalar?) -> Bool {
        guard let scalar else { return true }
        return scalar.properties.isWhitespace
    }

    private static func isPunctuation(_ scalar: Scalar?) -> Bool {
        guard let scalar else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
            .initialPunctuation, .finalPunctuation, .otherPunctuation,
            .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default: return false
        }
    }
}
