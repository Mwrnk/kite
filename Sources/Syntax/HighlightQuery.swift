import CTreeSitter
import EditorCore
import Foundation

/// A compiled highlights.scm, plus the text predicates (#eq?, #match?, #any-of?) that
/// tree-sitter leaves for the host to check.
final class HighlightQuery: @unchecked Sendable {   // built on a background queue, then used only on the main thread
    private let query: OpaquePointer
    private let cursor: OpaquePointer
    private let kinds: [TokenKind?]            // by capture id
    private let predicates: [[Predicate]]      // by pattern index

    private enum Operand { case capture(UInt32), text(String) }

    private enum Predicate {
        case eq(capture: UInt32, Operand, negated: Bool)
        case match(capture: UInt32, NSRegularExpression, negated: Bool)
        case anyOf(capture: UInt32, Set<String>, negated: Bool)
    }

    nonisolated(unsafe) private static var cache: [Language: HighlightQuery] = [:]

    /// Loads (once) and compiles the query for a language. Main thread only.
    @MainActor
    static func load(_ language: Language) -> HighlightQuery? {
        if let cached = cache[language] { return cached }
        guard let query = compile(language) else { return nil }
        cache[language] = query
        return query
    }

    /// The cached query, if it has been compiled already. Main thread only.
    @MainActor
    static func cached(_ language: Language) -> HighlightQuery? { cache[language] }

    /// Compiles on a background queue (it takes up to ~100 ms for big grammars), then hands the
    /// query to `done` on the main thread. Opening a window doesn't wait for it.
    @MainActor
    static func loadInBackground(_ language: Language, done: @escaping @MainActor (HighlightQuery?) -> Void) {
        if let cached = cache[language] { done(cached); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let query = compile(language)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let query, cache[language] == nil { cache[language] = query }
                    done(cache[language])
                }
            }
        }
    }

    /// Reads and compiles the query file. Safe on any thread.
    private static func compile(_ language: Language) -> HighlightQuery? {
        guard let url = resourceBundle?.url(forResource: language.rawValue, withExtension: "scm", subdirectory: "Queries"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return HighlightQuery(language: language, source: source)
    }

    init?(language: Language, source: String) {
        var errorOffset: UInt32 = 0
        var errorType = TSQueryErrorNone
        let utf8 = Array(source.utf8)
        guard let q = utf8.withUnsafeBufferPointer({ buf in
            buf.withMemoryRebound(to: CChar.self) {
                ts_query_new(language.tsLanguage, $0.baseAddress, UInt32($0.count), &errorOffset, &errorType)
            }
        }) else {
            print("Kite: highlight query for \(language) failed at byte \(errorOffset) (error \(errorType.rawValue))")
            return nil
        }
        query = q
        cursor = ts_query_cursor_new()

        func string(_ get: (OpaquePointer, UInt32, UnsafeMutablePointer<UInt32>) -> UnsafePointer<CChar>?, _ id: UInt32) -> String {
            var len: UInt32 = 0
            guard let p = get(q, id, &len) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: p, count: Int(len)), as: UTF8.self)
        }

        kinds = (0..<ts_query_capture_count(q)).map {
            TokenKind.from(captureName: string(ts_query_capture_name_for_id, $0))
        }

        var all: [[Predicate]] = []
        for pattern in 0..<ts_query_pattern_count(q) {
            var count: UInt32 = 0
            guard let steps = ts_query_predicates_for_pattern(q, pattern, &count), count > 0 else {
                all.append([]); continue
            }
            var list: [Predicate] = []
            var current: [TSQueryPredicateStep] = []
            for i in 0..<Int(count) {
                let step = steps[i]
                if step.type != TSQueryPredicateStepTypeDone { current.append(step); continue }
                defer { current.removeAll() }
                guard current.count >= 2, current[0].type == TSQueryPredicateStepTypeString,
                      current[1].type == TSQueryPredicateStepTypeCapture else { continue }
                let name = string(ts_query_string_value_for_id, current[0].value_id)
                let capture = current[1].value_id
                let args = current.dropFirst(2).map { s -> Operand in
                    s.type == TSQueryPredicateStepTypeCapture
                        ? .capture(s.value_id) : .text(string(ts_query_string_value_for_id, s.value_id))
                }
                let negated = name.hasPrefix("not-")
                switch name {
                case "eq?", "not-eq?":
                    if let arg = args.first { list.append(.eq(capture: capture, arg, negated: negated)) }
                case "match?", "not-match?", "lua-match?":
                    if case .text(let pattern)? = args.first,
                       let regex = try? NSRegularExpression(pattern: pattern) {
                        list.append(.match(capture: capture, regex, negated: negated))
                    }
                case "any-of?", "not-any-of?":
                    let words = args.compactMap { if case .text(let t) = $0 { t } else { nil } }
                    list.append(.anyOf(capture: capture, Set(words), negated: negated))
                default:
                    break  // #set!, #is-not? etc. don't affect coloring here
                }
            }
            all.append(list)
        }
        predicates = all
    }

    /// Finds the query files. Same places SwiftPM's `Bundle.module` looks, but returns nil
    /// (no colors) instead of crashing if the bundle is missing.
    private static let resourceBundle: Bundle? = {
        let candidates = [Bundle.main.resourceURL, Bundle(for: HighlightQuery.self).resourceURL, Bundle.main.bundleURL]
        for candidate in candidates {
            if let url = candidate?.appendingPathComponent("Kite_Syntax.bundle"), let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()

    deinit {
        ts_query_cursor_delete(cursor)
        ts_query_delete(query)
    }

    func run(on root: TSNode, range: Range<Int>, buffer: TextBuffer) -> [HighlightSpan] {
        ts_query_cursor_set_byte_range(cursor, UInt32(range.lowerBound), UInt32(range.upperBound))
        ts_query_cursor_exec(cursor, query, root)

        var found: [(span: HighlightSpan, pattern: UInt16)] = []
        var match = TSQueryMatch()
        while ts_query_cursor_next_match(cursor, &match) {
            let captures = UnsafeBufferPointer(start: match.captures, count: Int(match.capture_count))
            func text(of id: UInt32) -> String? {
                guard let c = captures.first(where: { $0.index == id }) else { return nil }
                return buffer.string(in: Int(ts_node_start_byte(c.node))..<Int(ts_node_end_byte(c.node)))
            }
            let ok = predicates[Int(match.pattern_index)].allSatisfy { p in
                switch p {
                case let .eq(capture, operand, negated):
                    let rhs: String? = switch operand { case .capture(let id): text(of: id); case .text(let t): t }
                    return (text(of: capture) == rhs) != negated
                case let .match(capture, regex, negated):
                    guard let s = text(of: capture) else { return true }
                    let hit = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
                    return hit != negated
                case let .anyOf(capture, words, negated):
                    guard let s = text(of: capture) else { return true }
                    return words.contains(s) != negated
                }
            }
            guard ok else { continue }
            for c in captures {
                guard let kind = kinds[Int(c.index)] else { continue }
                let start = Int(ts_node_start_byte(c.node)), end = Int(ts_node_end_byte(c.node))
                guard start < end else { continue }
                found.append((HighlightSpan(range: start..<end, kind: kind), match.pattern_index))
            }
        }
        // Outer nodes first, inner nodes after; for the same node, later patterns win
        // (that's how these grammars' queries are written).
        found.sort {
            if $0.span.range.lowerBound != $1.span.range.lowerBound { return $0.span.range.lowerBound < $1.span.range.lowerBound }
            if $0.span.range.count != $1.span.range.count { return $0.span.range.count > $1.span.range.count }
            return $0.pattern < $1.pattern
        }
        return found.map(\.span)
    }
}
