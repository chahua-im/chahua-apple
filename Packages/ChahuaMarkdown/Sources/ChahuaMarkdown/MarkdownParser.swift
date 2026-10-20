import Foundation

internal enum MarkdownParser {
    typealias Scalar = Unicode.Scalar

    /// Slices share the original scalar storage; nested lists only adjust line views.
    private struct Line {
        var text: ArraySlice<Scalar>
        var padding = 0
        var terminated: Bool

        var indentation: Int {
            var columns = padding
            for scalar in text {
                if scalar == " " {
                    columns += 1
                } else if scalar == "\t" {
                    columns += 4 - columns % 4
                } else {
                    break
                }
            }
            return columns
        }

        var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

        func removingIndent(_ count: Int) -> Line {
            var remaining = count
            var copy = self
            let fromPadding = min(copy.padding, remaining)
            copy.padding -= fromPadding
            remaining -= fromPadding
            var column = padding
            while remaining > 0, let scalar = copy.text.first, scalar == " " || scalar == "\t" {
                let width = scalar == "\t" ? 4 - column % 4 : 1
                copy.text = copy.text.dropFirst()
                let consumed = min(width, remaining)
                remaining -= consumed
                copy.padding += width - consumed
                column += width
            }
            return copy
        }

        func append(to output: inout [Scalar]) {
            output.append(contentsOf: repeatElement(" " as Scalar, count: padding))
            output.append(contentsOf: text)
        }
    }

    private struct ListMarker {
        var contentIndent: Int
        var content: Line
        var orderedStart: Int?
        var delimiter: Scalar
    }

    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\0", with: "\u{FFFD}")
        let scalars = Array(normalized.unicodeScalars)
        var lines: [Line] = []
        var start = 0
        for index in scalars.indices where scalars[index] == "\n" {
            lines.append(Line(text: scalars[start..<index], terminated: true))
            start = index + 1
        }
        if start < scalars.count { lines.append(Line(text: scalars[start...], terminated: false)) }
        var hasMarkup = InlineParser.hasEscapedPunctuation(source)
        let parsed = blocks(lines, depth: 0, hasMarkup: &hasMarkup)
        if hasMarkup { return parsed }
        let content = InlineParser.plain(source)
        return content.isEmpty ? [] : [.paragraph(content)]
    }

    private static func fence(_ line: Line) -> (count: Int, info: String)? {
        guard line.indentation < 4 else { return nil }
        let trimmed = line.removingIndent(line.indentation).text
        let count = trimmed.prefix(while: { $0 == "`" }).count
        guard count >= 3 else { return nil }
        let rest = trimmed.dropFirst(count)
        guard !rest.contains("`") else { return nil }
        return (count, scalarString(rest).trimmingCharacters(in: .whitespaces))
    }

    private static func closesFence(_ line: Line, count: Int) -> Bool {
        guard line.indentation < 4 else { return false }
        let trimmed = line.removingIndent(line.indentation).text
        let run = trimmed.prefix(while: { $0 == "`" }).count
        return run >= count && trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func marker(_ line: Line) -> ListMarker? {
        let indent = line.indentation
        guard indent < 4 else { return nil }
        let trimmed = line.removingIndent(indent)
        let text = trimmed.text
        guard let first = text.first else { return nil }
        var position = text.startIndex
        var start: Int?
        var delimiter = first
        if first == "-" || first == "+" {
            position += 1
        } else {
            var digits = 0
            var value = 0
            while position < text.endIndex, isDigit(text[position]), digits < 9 {
                value = value * 10 + Int(text[position].value - 48)
                position += 1
                digits += 1
            }
            guard digits > 0, position < text.endIndex,
                text[position] == "." || text[position] == ")"
            else { return nil }
            start = value
            delimiter = text[position]
            position += 1
        }
        guard position == text.endIndex || text[position] == " " || text[position] == "\t" else {
            return nil
        }
        let markerWidth = position - text.startIndex
        var column = indent + markerWidth
        let whitespaceStart = position
        while position < text.endIndex, text[position] == " " || text[position] == "\t" {
            column += text[position] == "\t" ? 4 - column % 4 : 1
            position += 1
        }
        let whitespace = column - indent - markerWidth
        let width = whitespace > 4 || position == text.endIndex ? 1 : max(whitespace, 1)
        var content = Line(text: text[whitespaceStart...], terminated: line.terminated)
        // Tabs after a marker are measured from the marker's absolute column.
        var toRemove = width
        var absoluteColumn = indent + markerWidth
        while toRemove > 0, let scalar = content.text.first, scalar == " " || scalar == "\t" {
            let scalarWidth = scalar == "\t" ? 4 - absoluteColumn % 4 : 1
            content.text = content.text.dropFirst()
            content.padding += max(scalarWidth - toRemove, 0)
            toRemove -= min(scalarWidth, toRemove)
            absoluteColumn += scalarWidth
        }
        return ListMarker(
            contentIndent: indent + markerWidth + width,
            content: content, orderedStart: start, delimiter: delimiter
        )
    }

    private static func interruptsParagraph(_ line: Line) -> Bool {
        if fence(line) != nil { return true }
        guard let marker = marker(line), !marker.content.isBlank else { return false }
        return marker.orderedStart == nil || marker.orderedStart == 1
    }

    private static func blocks(_ lines: [Line], depth: Int, hasMarkup: inout Bool)
        -> [MarkdownBlock]
    {
        var result: [MarkdownBlock] = []
        var position = 0
        while position < lines.count {
            if lines[position].isBlank {
                position += 1
                continue
            }
            if let opening = fence(lines[position]) {
                hasMarkup = true
                let indent = lines[position].indentation
                position += 1
                var content: [Scalar] = []
                while position < lines.count, !closesFence(lines[position], count: opening.count) {
                    lines[position].removingIndent(indent).append(to: &content)
                    if lines[position].terminated { content.append("\n") }
                    position += 1
                }
                if position < lines.count { position += 1 }
                let word = opening.info.split(whereSeparator: { $0.isWhitespace }).first.map(
                    String.init)
                let language = word.flatMap { candidate -> String? in
                    let valid =
                        !candidate.isEmpty
                        && candidate.unicodeScalars.allSatisfy {
                            isASCIIAlphaNumeric($0) || $0 == "_" || $0 == "+" || $0 == "-"
                        }
                    return valid ? candidate : nil
                }
                result.append(.codeBlock(language: language, code: scalarString(content)))
                continue
            }
            if depth < 100, let first = marker(lines[position]) {
                hasMarkup = true
                var items: [[MarkdownBlock]] = []
                while position < lines.count, let current = marker(lines[position]),
                    current.delimiter == first.delimiter,
                    (current.orderedStart == nil) == (first.orderedStart == nil)
                {
                    var itemLines = [current.content]
                    position += 1
                    var blankSeen = false
                    var lazy = !current.content.isBlank && fence(current.content) == nil
                    var activeFence = fence(current.content)?.count
                    while position < lines.count {
                        let line = lines[position]
                        if line.isBlank {
                            itemLines.append(line)
                            blankSeen = true
                            position += 1
                            continue
                        }
                        if line.indentation >= current.contentIndent {
                            let child = line.removingIndent(current.contentIndent)
                            itemLines.append(child)
                            if let count = activeFence {
                                if closesFence(child, count: count) { activeFence = nil }
                                lazy = false
                            } else if let opening = fence(child) {
                                activeFence = opening.count
                                lazy = false
                            } else {
                                lazy = true
                            }
                            blankSeen = false
                            position += 1
                            continue
                        }
                        if marker(line) != nil || interruptsParagraph(line) || blankSeen || !lazy {
                            break
                        }
                        // CommonMark lazy continuation is only available to an open paragraph.
                        itemLines.append(line)
                        position += 1
                    }
                    items.append(blocks(itemLines, depth: depth + 1, hasMarkup: &hasMarkup))
                }
                result.append(.list(orderedStart: first.orderedStart, items: items))
                continue
            }
            var paragraph: [Scalar] = []
            repeat {
                let line = lines[position]
                let trimmed = line.removingIndent(line.indentation).text
                if !paragraph.isEmpty { paragraph.append("\n") }
                var end = trimmed.endIndex
                while end > trimmed.startIndex, trimmed[end - 1] == " " || trimmed[end - 1] == "\t"
                { end -= 1 }
                paragraph.append(contentsOf: trimmed[..<end])
                position += 1
            } while position < lines.count && !lines[position].isBlank
                && !interruptsParagraph(lines[position])
            result.append(.paragraph(InlineParser.parse(paragraph, hasMarkup: &hasMarkup)))
        }
        return result
    }
}

internal func scalarString<S: Sequence>(_ scalars: S) -> String where S.Element == Unicode.Scalar {
    String(String.UnicodeScalarView(scalars))
}

internal func isDigit(_ scalar: Unicode.Scalar) -> Bool {
    scalar.value >= 48 && scalar.value <= 57
}

internal func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
    isDigit(scalar) || (scalar.value >= 65 && scalar.value <= 90)
        || (scalar.value >= 97 && scalar.value <= 122)
}
