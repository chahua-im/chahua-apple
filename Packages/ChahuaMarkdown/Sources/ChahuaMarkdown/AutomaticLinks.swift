import Foundation

/// The default linkify-it domain/TLD/path grammar used by the PWA. Using its
/// fixed grammar avoids NSDataDetector's OS-dependent TLD and punctuation rules.
internal enum AutomaticLinks {
    struct Match {
        let text: String
        let destination: String
        let end: Int
    }

    private static let expressions: [(regex: NSRegularExpression, explicit: Bool)] = {
        let spaceControl = #"\p{Z}\p{Cc}"#
        let punctuation = #"\p{Z}\p{P}\p{Cc}"#
        let separators = "><｜"
        let letter = "(?:(?![\(separators)\(punctuation)])[\\s\\S])"
        let punycode = #"xn--[a-z0-9\-]{1,59}"#
        let domain = "(?:\(punycode)|\(letter)(?:-|\(letter)){0,61}\(letter)|\(letter))"
        let host = "(?:\(domain)\\.)*\(domain)"
        let twoLetterTLD =
            "a[cdefgilmnoqrstuwxz]|b[abdefghijmnorstvwyz]|c[acdfghiklmnoruvwxyz]|d[ejkmoz]|e[cegrstu]|f[ijkmor]|g[abdefghilmnpqrstuwy]|h[kmnrtu]|i[delmnoqrst]|j[emop]|k[eghimnprwyz]|l[abcikrstuvy]|m[acdeghklmnopqrstuvwxyz]|n[acefgilopruz]|om|p[aefghklmnrstwy]|qa|r[eosuw]|s[abcdeghijklmnortuvxyz]|t[cdfghjklmnortvwz]|u[agksyz]|v[aceginu]|w[fs]|y[et]|z[amw]"
        let tlds =
            "biz|com|edu|gov|net|org|pro|web|xxx|aero|asia|coop|info|museum|name|shop|рф|\(twoLetterTLD)|\(punycode)"
        let fuzzyHost = "(?:\(domain)\\.)+(?:\(tlds))"
        let port = #"(?::(?:6(?:[0-4]\d{3}|5(?:[0-4]\d{2}|5(?:[0-2]\d|3[0-5])))|[1-5]?\d{1,4}))?"#
        // A closing double underscore belongs to surrounding formatting, not the host.
        let terminator =
            "(?=$|[\(separators)\(punctuation)])(?!-|_(?!_)|:\\d|\\.-|\\.(?!$|[\(punctuation)]))"
        let path =
            "(?:[/?#](?:"
            + "(?![\(spaceControl)\(separators)()\\[\\]{}.,\"'?!\\-;])[\\s\\S]|"
            + "\\[(?:(?![\(spaceControl)\\]])[\\s\\S])*\\]|"
            + "\\((?:(?![\(spaceControl))])[\\s\\S])*\\)|"
            + "\\{(?:(?![\(spaceControl)}])[\\s\\S])*\\}|"
            + "\"(?:(?![\(spaceControl)\"])[\\s\\S])+\"|"
            + "'(?:(?![\(spaceControl)'])[\\s\\S])+'|"
            + "'(?=\(letter)|-)|"
            + #"\.{2,}[a-zA-Z0-9%/&]|"#
            + "\\.(?![\(spaceControl).]|$)|"
            + #"\-+|"#
            + ",(?![\(spaceControl)]|$)|"
            + ";(?![\(spaceControl)]|$)|"
            + "\\!+(?![\(spaceControl)!]|$)|"
            + "\\?(?![\(spaceControl)?]|$)"
            + ")+|/)?"
        let authentication = "(?:(?:(?![\(spaceControl)@/\\[\\]()])[\\s\\S]){1,50}@)?"
        let explicit =
            "(?<![\\p{L}\\p{N}])(?<url>https?://\(authentication)\(host)\(port)\(terminator)\(path))"
        let fuzzyPrefix = "(?:^|(?![.:/\\\\\\-_@])[$+<=>^`|｜\(punctuation)])"
        let fuzzy = "\(fuzzyPrefix)(?<url>(?![$+<=>^`|｜])\(fuzzyHost)\(port)\(terminator)\(path))"
        return [
            (try! NSRegularExpression(pattern: explicit, options: .caseInsensitive), true),
            (try! NSRegularExpression(pattern: fuzzy, options: .caseInsensitive), false),
        ]
    }()

    static func matches(_ source: [Unicode.Scalar], explicitOnly: Bool = false) -> [Int: Match] {
        guard source.contains(".") || source.contains(":") else { return [:] }
        let text = scalarString(source)
        let length = text.utf16.count
        var candidates: [(range: NSRange, explicit: Bool)] = []
        for expression in expressions {
            if explicitOnly && !expression.explicit { continue }
            for match in expression.regex.matches(
                in: text, range: NSRange(location: 0, length: length))
            {
                var range = match.range(withName: "url")
                // markdown-it's early URL rule leaves trailing stars to its emphasis rule.
                while range.length > 0,
                    (text as NSString).character(at: NSMaxRange(range) - 1) == 42
                {
                    range.length -= 1
                }
                candidates.append((range, expression.explicit))
            }
        }
        guard !candidates.isEmpty else { return [:] }
        candidates.sort {
            if $0.range.location != $1.range.location {
                return $0.range.location < $1.range.location
            }
            return $0.explicit && !$1.explicit
        }
        var scalarAtUTF16 = Array(repeating: -1, count: length + 1)
        var offset = 0
        for (index, scalar) in source.enumerated() {
            scalarAtUTF16[offset] = index
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
        scalarAtUTF16[offset] = source.count
        var result: [Int: Match] = [:]
        var consumed = 0
        for candidate in candidates {
            guard candidate.range.location >= consumed else { continue }
            let start = scalarAtUTF16[candidate.range.location]
            let end = scalarAtUTF16[NSMaxRange(candidate.range)]
            guard start >= 0, end >= 0 else { continue }
            // Fuzzy email tokens are rendered as text by the PWA's safe-link
            // policy; never turn a dotted email local part into a domain link.
            if !candidate.explicit, end < source.count, source[end] == "@" { continue }
            let label = (text as NSString).substring(with: candidate.range)
            result[start] = Match(
                text: label, destination: candidate.explicit ? label : "http://" + label, end: end)
            consumed = NSMaxRange(candidate.range)
        }
        return result
    }
}

// Domain/TLD/path expressions adapted from linkify-it, copyright (c) 2015
// Vitaly Puzrin. MIT License:
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
