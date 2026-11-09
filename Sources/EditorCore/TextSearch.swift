import Foundation

/// Search through whole files, used by project-wide search and replace.
public enum TextSearch {
    public struct Match: Sendable, Equatable {
        /// 0-based line and byte column, in the file as Kite shows it (see `text(of:)`).
        public let line: Int
        public let column: Int
        /// Byte offset in the whole text.
        public let offset: Int
        public let length: Int
        /// The line's text (trimmed, at most ~160 characters) and where the match sits in it.
        public let preview: String
        public let previewRange: Range<Int>   // UTF-8 offsets into `preview`
        /// What the match becomes, when searching with a replacement.
        public let replacement: String?
    }

    /// Files larger than this are skipped, as are files that look binary.
    public static let maxFileSize = 4_000_000

    /// A file's text as Kite shows it (decoded like the editor does, "\n" line endings), or nil
    /// if it's too large or looks binary.
    public static func text(of data: Data) -> String? {
        guard data.count <= maxFileSize else { return nil }
        let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        if !utf16 && data.prefix(8192).contains(0) { return nil }
        return TextFileCodec.decode(data).text
    }

    /// Matches of `query` in a file's text (see `text(of:)`). With a `template`, each match also
    /// carries its replacement, and empty matches (like `^`) count too.
    public static func matches(of query: FindQuery, in text: String, template: String? = nil,
                               limit: Int = 200) -> [Match] {
        let found: [(range: Range<Int>, text: String?)] = if let template {
            query.replacements(in: text, template: template).prefix(limit).map { ($0.range, $0.text) }
        } else {
            query.matches(in: text, includeEmpty: false, limit: limit).map { ($0, nil) }
        }
        guard !found.isEmpty else { return [] }
        let bytes = Array(text.utf8)
        var results: [Match] = []
        var line = 0, lineStart = 0, scanned = 0
        for (range, replacement) in found {
            let i = range.lowerBound
            while scanned < i {
                if bytes[scanned] == 0x0A { line += 1; lineStart = scanned + 1 }
                scanned += 1
            }
            var lineEnd = i
            while lineEnd < bytes.count && bytes[lineEnd] != 0x0A { lineEnd += 1 }
            results.append(match(bytes: bytes, line: line, lineStart: lineStart, lineEnd: lineEnd,
                                 at: i, length: range.count, replacement: replacement))
        }
        return results
    }

    private static func match(bytes: [UInt8], line: Int, lineStart: Int, lineEnd: Int, at i: Int, length n: Int,
                              replacement: String?) -> Match {
        // Trim leading whitespace and keep a window of the line around the match.
        var from = lineStart
        while from < i && (bytes[from] == 0x20 || bytes[from] == 0x09) { from += 1 }
        var cut = false
        if i - from > 24 { from = i - 16; cut = true }   // keep the match near the start, so it shows in a narrow sidebar
        var to = max(min(lineEnd, max(i + n + 100, from + 160)), i)
        // Don't cut a multi-byte character in half.
        while from > lineStart && bytes[from] & 0xC0 == 0x80 { from -= 1 }
        while to < lineEnd && bytes[to] & 0xC0 == 0x80 { to += 1 }
        let lead = cut ? "…" : ""
        let preview = lead + String(decoding: bytes[from..<to], as: UTF8.self)
        let offset = lead.utf8.count + (i - from)
        let column = i - lineStart
        // A match running past the end of its line is marked up to the line's end.
        let shown = min(n, to - i)
        return Match(line: line, column: column, offset: i, length: n, preview: preview,
                     previewRange: offset..<(offset + shown), replacement: replacement)
    }

}
