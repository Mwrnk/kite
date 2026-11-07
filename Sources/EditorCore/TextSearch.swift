import Foundation

/// Plain-text search through a file's bytes, used by project-wide search.
public enum TextSearch {
    public struct Match: Sendable, Equatable {
        /// 0-based line and byte column, in the file as Kite shows it (line endings normalized,
        /// no byte-order mark).
        public let line: Int
        public let column: Int
        public let length: Int
        /// The line's text (trimmed, at most ~160 characters) and where the match sits in it.
        public let preview: String
        public let previewRange: Range<Int>   // UTF-8 offsets into `preview`
    }

    /// Files larger than this are skipped, as are files that look binary.
    public static let maxFileSize = 4_000_000

    /// All matches of `query` in `data`. Case-insensitive matching folds ASCII letters only.
    public static func matches(of query: String, in data: Data, caseSensitive: Bool, limit: Int = 200) -> [Match] {
        let needle = Array(query.utf8).map { caseSensitive ? $0 : lower($0) }
        guard !needle.isEmpty, data.count <= maxFileSize else { return [] }
        var bytes = [UInt8](data)
        if bytes.prefix(8192).contains(0) { return [] }               // binary
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }  // UTF-8 BOM
        let hay = caseSensitive ? bytes : bytes.map(lower)

        var results: [Match] = []
        var line = 0, lineStart = 0, scanned = 0
        var i = 0
        let first = needle[0], n = needle.count
        while i + n <= hay.count {
            guard hay[i] == first, hay[i..<(i + n)].elementsEqual(needle) else { i += 1; continue }
            // Advance the line counter to the match.
            while scanned < i {
                if bytes[scanned] == 0x0A { line += 1; lineStart = scanned + 1 }
                scanned += 1
            }
            var lineEnd = i
            while lineEnd < bytes.count && bytes[lineEnd] != 0x0A && bytes[lineEnd] != 0x0D { lineEnd += 1 }
            results.append(match(bytes: bytes, line: line, lineStart: lineStart, lineEnd: lineEnd, at: i, length: n))
            if results.count >= limit { break }
            i += n
        }
        return results
    }

    private static func match(bytes: [UInt8], line: Int, lineStart: Int, lineEnd: Int, at i: Int, length n: Int) -> Match {
        // Trim leading whitespace and keep a window of the line around the match.
        var from = lineStart
        while from < i && (bytes[from] == 0x20 || bytes[from] == 0x09) { from += 1 }
        var cut = false
        if i - from > 24 { from = i - 16; cut = true }   // keep the match near the start, so it shows in a narrow sidebar
        var to = min(lineEnd, max(i + n + 100, from + 160))
        // Don't cut a multi-byte character in half.
        while from > lineStart && bytes[from] & 0xC0 == 0x80 { from -= 1 }
        while to < lineEnd && bytes[to] & 0xC0 == 0x80 { to += 1 }
        let lead = cut ? "…" : ""
        let preview = lead + String(decoding: bytes[from..<to], as: UTF8.self)
        let offset = lead.utf8.count + (i - from)
        let column = i - lineStart
        return Match(line: line, column: column, length: n, preview: preview, previewRange: offset..<(offset + n))
    }

    private static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }
}
