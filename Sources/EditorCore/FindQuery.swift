import Foundation

/// The find bar's switches.
public struct FindOptions: Sendable, Equatable, Codable {
    public var caseSensitive: Bool
    public var wholeWord: Bool
    public var regex: Bool

    public init(caseSensitive: Bool = false, wholeWord: Bool = false, regex: Bool = false) {
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
        self.regex = regex
    }
}

/// A compiled search, shared by the find bar, the highlights and project search.
///
/// Everything runs on ICU regular expressions: plain text is escaped first, and "whole word"
/// means no letter, digit or `_` right before or after the match. `^` and `$` match at every
/// line, and a match may span lines. Offsets in and out are UTF-8 bytes, like the buffer's.
///
/// Matching can be slow for some patterns (`(a+)+b` on a long run of `a`s never finishes),
/// so run it off the main thread on whole files.
public struct FindQuery: @unchecked Sendable {   // NSRegularExpression is immutable and thread-safe
    public let pattern: String
    public let options: FindOptions
    private let regex: NSRegularExpression

    public enum Problem: Error, Equatable {
        case empty
        /// The pattern isn't a valid regular expression.
        case invalid
    }

    public init(_ pattern: String, options: FindOptions = FindOptions()) throws(Problem) {
        guard !pattern.isEmpty else { throw .empty }
        var source = options.regex ? pattern : NSRegularExpression.escapedPattern(for: pattern)
        if options.wholeWord { source = "(?<![\\p{L}\\p{N}_])(?:\(source))(?![\\p{L}\\p{N}_])" }
        var flags: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: source, options: flags) else { throw .invalid }
        self.pattern = pattern
        self.options = options
        self.regex = regex
    }

    // MARK: Matching

    /// Matches in `text`, as byte ranges plus `base`. With `within` (bytes of `text`), only matches
    /// inside it count, but `^`, `\b` and lookarounds still see the text around it.
    public func matches(in text: String, base: Int = 0, within: Range<Int>? = nil,
                        includeEmpty: Bool = true, limit: Int = .max) -> [Range<Int>] {
        var out: [Range<Int>] = []
        enumerate(in: text, within: within) { result, range in
            if includeEmpty || !range.isEmpty { out.append((range.lowerBound + base)..<(range.upperBound + base)) }
            return out.count < limit
        }
        return out
    }

    /// Every match with its replacement text, for Replace All.
    public func replacements(in text: String, base: Int = 0, within: Range<Int>? = nil,
                             template: String) -> [(range: Range<Int>, text: String)] {
        var out: [(Range<Int>, String)] = []
        enumerate(in: text, within: within) { result, range in
            out.append(((range.lowerBound + base)..<(range.upperBound + base), expand(template, result, in: text)))
            return true
        }
        return out
    }

    /// The replacement for the match covering exactly `range` (bytes of `text`), or nil if the
    /// text there isn't a match (for example, after it was edited).
    public func replacement(forMatchAt range: Range<Int>, in text: String, template: String) -> String? {
        // Match from the start of `range` with nothing holding it back at the end, so a partial
        // match ("1" of "12") doesn't count.
        var found: String?
        enumerate(in: text, within: range.lowerBound..<text.utf8.count, anchored: true) { result, r in
            if r == range { found = expand(template, result, in: text) }
            return false
        }
        return found
    }

    /// Calls `body` with each match and its byte range, until it returns false.
    private func enumerate(in text: String, within: Range<Int>?, anchored: Bool = false,
                           _ body: (NSTextCheckingResult, Range<Int>) -> Bool) {
        let utf8 = text.utf8
        var searchRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let within {
            let lo = utf8.index(utf8.startIndex, offsetBy: min(max(within.lowerBound, 0), utf8.count))
            let hi = utf8.index(utf8.startIndex, offsetBy: min(max(within.upperBound, 0), utf8.count))
            searchRange = NSRange(lo..<hi, in: text)
        }
        var options: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        if anchored { options.insert(.anchored) }
        regex.enumerateMatches(in: text, options: options,
                               range: searchRange) { result, _, stop in
            guard let result, let r = Range(result.range, in: text) else { return }
            let range = utf8.distance(from: utf8.startIndex, to: r.lowerBound)..<utf8.distance(from: utf8.startIndex, to: r.upperBound)
            if !body(result, range) { stop.pointee = true }
        }
    }

    // MARK: Replacement text

    /// Fills in a replacement. In regex mode, `$0`–`$99`, `${2}` and `${name}` insert groups,
    /// `\n` and `\t` insert a newline and a tab, and `\$` or `\\` insert the character itself.
    /// Otherwise the replacement is used exactly as typed.
    private func expand(_ template: String, _ result: NSTextCheckingResult, in text: String) -> String {
        guard options.regex else { return template }
        let nsText = text as NSString
        func group(_ range: NSRange) -> String { range.location == NSNotFound ? "" : nsText.substring(with: range) }

        var out = ""
        var chars = Array(template)
        var i = 0
        func digits(from start: Int) -> (Int, Int)? {   // value and count of 1–2 digits
            var n = 0, count = 0
            while start + count < chars.count, count < 2, let d = chars[start + count].wholeNumberValue, chars[start + count].isASCII {
                let next = n * 10 + d
                if count == 1 && next >= result.numberOfRanges { break }   // "$12" with one group is "$1" then "2"
                n = next; count += 1
            }
            return count > 0 ? (n, count) : nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                switch chars[i + 1] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(chars[i + 1])
                }
                i += 2
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "{",
                      let close = chars[(i + 2)...].firstIndex(of: "}") {
                let name = String(chars[(i + 2)..<close])
                if let n = Int(name) {
                    if n < result.numberOfRanges { out += group(result.range(at: n)) }
                } else {
                    out += group(result.range(withName: name))
                }
                i = close + 1
            } else if c == "$", let (n, count) = digits(from: i + 1), n < result.numberOfRanges {
                out += group(result.range(at: n))
                i += 1 + count
            } else {
                out.append(c)
                i += 1
            }
        }
        chars = []
        return out
    }
}

// MARK: - Picking the next match

extension FindQuery {
    /// The match to go to from a selection, in a sorted list. Forward: the first one starting after
    /// `selection`'s end (or at it, if not empty). Backward: the last one starting before its start.
    /// Wraps around. Never returns the empty match the selection already is.
    public static func next(in matches: [Range<Int>], after selection: Range<Int>, backwards: Bool) -> Range<Int>? {
        guard !matches.isEmpty else { return nil }
        if backwards {
            let i = firstIndex(in: matches) { $0.lowerBound >= selection.lowerBound }
            return i > 0 ? matches[i - 1] : matches.last
        }
        let i = firstIndex(in: matches) {
            $0.lowerBound > selection.upperBound || ($0.lowerBound == selection.upperBound && !$0.isEmpty)
        }
        return i < matches.count ? matches[i] : matches.first
    }

    /// Index of the first element where `isAfter` turns true (binary search; it must be monotonic).
    public static func firstIndex(in matches: [Range<Int>], where isAfter: (Range<Int>) -> Bool) -> Int {
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isAfter(matches[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
