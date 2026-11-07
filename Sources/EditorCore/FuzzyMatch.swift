/// Fuzzy matching for quick open: the query's characters must appear in order, not necessarily
/// together. Matches in the file name, at word starts and in unbroken runs score higher, and
/// shorter paths win ties.
public struct FuzzyCandidate: Sendable {
    public let text: String
    let lower: [UInt8]
    let original: [UInt8]
    /// Byte index where the file name starts (after the last "/").
    let nameStart: Int

    public init(_ text: String) {
        self.text = text
        original = Array(text.utf8)
        lower = original.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }
        nameStart = (original.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
    }
}

public enum FuzzyMatch {
    public struct Result: Sendable {
        public let score: Int
        /// Matched byte offsets in the candidate's text, for highlighting.
        public let positions: [Int]

        public init(score: Int, positions: [Int]) {
            self.score = score
            self.positions = positions
        }
    }

    /// Nil when the query's characters don't all appear in order.
    public static func match(_ query: String, _ candidate: FuzzyCandidate) -> Result? {
        let q = Array(query.utf8).map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }.filter { $0 != UInt8(ascii: " ") }
        guard !q.isEmpty else { return Result(score: 0, positions: []) }
        // Try to fit the whole query in the file name first; fall back to the whole path.
        var best: Result?
        for start in [candidate.nameStart, 0] {
            guard let positions = positions(of: q, in: candidate, from: start) else { continue }
            let result = Result(score: score(positions, candidate), positions: positions)
            if best == nil || result.score > best!.score { best = result }
        }
        return best
    }

    /// Ranks candidates for a query, best first.
    public static func rank(_ query: String, _ candidates: [FuzzyCandidate], limit: Int = 50) -> [(index: Int, result: Result)] {
        var hits: [(index: Int, result: Result)] = []
        for (i, c) in candidates.enumerated() {
            if let r = match(query, c) { hits.append((i, r)) }
        }
        hits.sort {
            $0.result.score != $1.result.score ? $0.result.score > $1.result.score
                : candidates[$0.index].original.count < candidates[$1.index].original.count
        }
        return Array(hits.prefix(limit))
    }

    /// Greedy left-to-right match that prefers a word start when one is close ahead.
    private static func positions(of q: [UInt8], in c: FuzzyCandidate, from start: Int) -> [Int]? {
        var out: [Int] = []
        out.reserveCapacity(q.count)
        var i = start
        for (k, ch) in q.enumerated() {
            guard let found = (i..<c.lower.count).first(where: { c.lower[$0] == ch }) else { return nil }
            var pick = found
            // If the previous match isn't directly before `found`, a word start a little further on
            // reads better ("ev" in "EditorView" → the V of View, not the v in "evaluate"), as long
            // as the rest of the query still fits after it.
            if let last = out.last, found != last + 1,
               let boundary = (found..<min(c.lower.count, found + 24)).first(where: {
                   c.lower[$0] == ch && isWordStart($0, c) && fits(q[(k + 1)...], in: c, from: $0 + 1)
               }) {
                pick = boundary
            }
            out.append(pick)
            i = pick + 1
        }
        return out
    }

    private static func fits(_ rest: ArraySlice<UInt8>, in c: FuzzyCandidate, from start: Int) -> Bool {
        var i = start
        for ch in rest {
            while i < c.lower.count && c.lower[i] != ch { i += 1 }
            if i == c.lower.count { return false }
            i += 1
        }
        return true
    }

    private static func isWordStart(_ i: Int, _ c: FuzzyCandidate) -> Bool {
        if i == 0 || i == c.nameStart { return true }
        let prev = c.original[i - 1], cur = c.original[i]
        if "/_-. ".utf8.contains(prev) { return true }
        return (65...90).contains(cur) && (97...122).contains(prev)   // camelCase hump
    }

    private static func score(_ positions: [Int], _ c: FuzzyCandidate) -> Int {
        var score = 0
        var previous = -2
        for p in positions {
            score += 1
            if p >= c.nameStart { score += 3 }
            if isWordStart(p, c) { score += 8 }
            if p == previous + 1 { score += 6 } else if previous >= 0 { score -= min(p - previous - 1, 4) }
            previous = p
        }
        if positions.first == c.nameStart { score += 6 }
        return score * 16 - c.original.count / 4
    }
}
