import CTreeSitter
import Dispatch
import EditorCore
import Foundation

/// Keeps a tree-sitter parse tree in sync with a TextBuffer and answers highlight queries.
///
/// Parsing runs on a background queue so typing never waits for it. Between an edit and the
/// end of the next parse, the previous tree is shifted with `ts_tree_edit`, so colors stay
/// lined up with the text; `onUpdate` fires when a fresh tree is ready.
@MainActor
public final class SyntaxTree {
    public let language: Language
    let buffer: TextBuffer
    private let worker: ParseWorker
    /// Compiled in the background when the tree is made; no colors until it's ready.
    private var query: HighlightQuery?
    /// Markdown only: colors for the text inside paragraphs and headings.
    private var inlineQuery: HighlightQuery?
    var tree: TreeBox?

    private var dirty = true
    private var parsing = false
    private var generation = 0
    private var appliedGeneration = 0
    private var editsDuringParse: [TSInputEdit] = []

    /// Called on the main thread when a new parse finishes and colors may have changed.
    public var onUpdate: (() -> Void)?

    /// Files larger than this are shown without colors, to keep memory and parse time bounded.
    public static let maxBytes = 8 * 1024 * 1024

    public init?(language: Language, buffer: TextBuffer) {
        guard buffer.byteCount <= Self.maxBytes,
              let worker = ParseWorker(language: language) else { return nil }
        self.language = language
        self.buffer = buffer
        self.worker = worker
        query = HighlightQuery.cached(language)
        buffer.addObserver { [weak self] edit in self?.apply(edit) }
        scheduleParse()
        if query == nil {
            HighlightQuery.loadInBackground(language) { [weak self] query in
                guard let self, self.query == nil else { return }
                self.query = query
                if query != nil { self.onUpdate?() }
            }
        }
        if language == .markdown {
            inlineQuery = HighlightQuery.cached(.markdownInline)
            if inlineQuery == nil {
                HighlightQuery.loadInBackground(.markdownInline) { [weak self] query in
                    guard let self, self.inlineQuery == nil else { return }
                    self.inlineQuery = query
                    if query != nil { self.onUpdate?() }
                }
            }
        }
    }

    private func apply(_ edit: BufferEdit) {
        var e = TSInputEdit(
            start_byte: UInt32(edit.startByte), old_end_byte: UInt32(edit.oldEndByte),
            new_end_byte: UInt32(edit.newEndByte),
            start_point: TSPoint(edit.startPoint), old_end_point: TSPoint(edit.oldEndPoint),
            new_end_point: TSPoint(edit.newEndPoint))
        tree?.edit(&e)
        if parsing { editsDuringParse.append(e) }
        dirty = true
        scheduleParse()
    }

    private func scheduleParse() {
        guard dirty, !parsing else { return }
        guard buffer.byteCount <= Self.maxBytes else { tree = nil; dirty = false; return }
        dirty = false
        parsing = true
        editsDuringParse = []
        generation += 1
        let gen = generation
        let snapshot = buffer.storage  // value copy; the original bytes are shared, not copied
        let old = tree?.copy()
        let worker = self.worker
        worker.queue.async {
            let result = worker.parse(snapshot, old: old)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result, generation: gen) }
            }
        }
    }

    private func finish(_ result: TreeBox?, generation gen: Int) {
        parsing = false
        if gen > appliedGeneration, let result {
            // Edits made while parsing: shift the new tree to match the current text.
            for var e in editsDuringParse { result.edit(&e) }
            tree = result
            appliedGeneration = gen
            onUpdate?()
        }
        editsDuringParse = []
        scheduleParse()
    }

    /// Parses right now on the calling thread (for tests and tools). The UI never needs this.
    public func parseSynchronously() {
        if query == nil { query = HighlightQuery.load(language) }   // tools and tests want colors right away
        if language == .markdown, inlineQuery == nil { inlineQuery = HighlightQuery.load(.markdownInline) }
        guard dirty || parsing || tree == nil else { return }
        let snapshot = buffer.storage
        let old = tree?.copy()
        let worker = self.worker
        // The worker queue is serial, so this also waits for any parse already running.
        let result = worker.queue.sync { worker.parse(snapshot, old: old) }
        generation += 1
        appliedGeneration = generation
        tree = result
        dirty = false
        editsDuringParse = []
    }

    /// Highlighted spans overlapping `range`, ordered so later spans should paint over earlier ones.
    public func highlights(in range: Range<Int>) -> [HighlightSpan] {
        guard let tree, let query else { return [] }
        var spans = query.run(on: ts_tree_root_node(tree.pointer), range: range, buffer: buffer)
        if let inlineQuery, let inline = tree.inlinePointer {
            spans += inlineQuery.run(on: ts_tree_root_node(inline), range: range, buffer: buffer)
        }
        return spans
    }

    /// True once a parse result matches the current text.
    public var isUpToDate: Bool { !dirty && !parsing && tree != nil }

    /// The tree as an S-expression (for debugging and tests).
    public var debugDescription: String {
        parseSynchronously()
        guard let tree, let cString = ts_node_string(ts_tree_root_node(tree.pointer)) else { return "" }
        defer { free(cString) }
        return String(cString: cString)
    }
}

extension TSPoint {
    init(_ p: TextPoint) { self.init(row: UInt32(p.row), column: UInt32(p.column)) }
}

/// Owns a tree-sitter tree. Trees are immutable once handed between threads
/// (we only edit the main thread's own copy), so sharing the box is safe.
final class TreeBox: @unchecked Sendable {
    let pointer: OpaquePointer
    /// Markdown only: a second tree over the text of the first tree's `inline` nodes.
    let inlinePointer: OpaquePointer?

    init(_ pointer: OpaquePointer, inline: OpaquePointer? = nil) {
        self.pointer = pointer
        inlinePointer = inline
    }

    func copy() -> TreeBox {
        TreeBox(ts_tree_copy(pointer), inline: inlinePointer.flatMap { ts_tree_copy($0) })
    }

    func edit(_ e: inout TSInputEdit) {
        ts_tree_edit(pointer, &e)
        if let inlinePointer { ts_tree_edit(inlinePointer, &e) }
    }

    deinit {
        ts_tree_delete(pointer)
        if let inlinePointer { ts_tree_delete(inlinePointer) }
    }
}

/// Owns the parser. Only used on `queue`.
final class ParseWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "kite.syntax.parse", qos: .userInitiated)
    private let parser: OpaquePointer
    /// Markdown only: parses the text inside the block tree's `inline` nodes.
    private let inlineParser: OpaquePointer?
    /// Above this, Markdown keeps its block colors only. The inline parse jumps between thousands of
    /// separate ranges and its time grows with the square of the file size (28 s at 5.6 MB).
    static let maxInlineBytes = 512 * 1024

    init?(language: Language) {
        parser = ts_parser_new()
        guard ts_parser_set_language(parser, language.tsLanguage) else {
            ts_parser_delete(parser)
            return nil
        }
        if language == .markdown, let inline = ts_parser_new() {
            guard ts_parser_set_language(inline, Language.markdownInline.tsLanguage) else {
                ts_parser_delete(inline)
                ts_parser_delete(parser)
                return nil
            }
            inlineParser = inline
        } else {
            inlineParser = nil
        }
    }

    deinit {
        ts_parser_delete(parser)
        if let inlineParser { ts_parser_delete(inlineParser) }
    }

    func parse(_ text: PieceTable, old: TreeBox?) -> TreeBox? {
        let reader = InputReader(text: text)
        let input = TSInput(
            payload: Unmanaged.passUnretained(reader).toOpaque(),
            read: readCallback,
            encoding: TSInputEncodingUTF8,
            decode: nil)
        return withExtendedLifetime(reader) {
            guard let blocks = ts_parser_parse(parser, old?.pointer, input) else { return nil }
            guard let inlineParser, text.count <= Self.maxInlineBytes else { return TreeBox(blocks) }
            let ranges = inlineRanges(in: ts_tree_root_node(blocks))
            // With no ranges, tree-sitter would parse the whole file as inline text.
            guard !ranges.isEmpty, ts_parser_set_included_ranges(inlineParser, ranges, UInt32(ranges.count)) else {
                return TreeBox(blocks)
            }
            return TreeBox(blocks, inline: ts_parser_parse(inlineParser, old?.inlinePointer, input))
        }
    }

    /// The text of every `inline` node, in order, without the children inside it (the `> ` that
    /// starts each line of a quoted paragraph isn't part of the text).
    private func inlineRanges(in root: TSNode) -> [TSRange] {
        var out: [TSRange] = []
        var cursor = ts_tree_cursor_new(root)
        defer { ts_tree_cursor_delete(&cursor) }
        while true {
            let node = ts_tree_cursor_current_node(&cursor)
            // By name: the grammar has several symbols that all appear as `inline`.
            if strcmp(ts_node_type(node), "inline") == 0 {
                appendText(of: node, to: &out)
            } else if ts_tree_cursor_goto_first_child(&cursor) {
                continue
            }
            while !ts_tree_cursor_goto_next_sibling(&cursor) {
                if !ts_tree_cursor_goto_parent(&cursor) { return out }
            }
        }
    }

    private func appendText(of node: TSNode, to out: inout [TSRange]) {
        var startByte = ts_node_start_byte(node), startPoint = ts_node_start_point(node)
        func add(upTo endByte: UInt32, _ endPoint: TSPoint) {
            guard startByte < endByte else { return }
            out.append(TSRange(start_point: startPoint, end_point: endPoint, start_byte: startByte, end_byte: endByte))
        }
        var cursor = ts_tree_cursor_new(node)
        defer { ts_tree_cursor_delete(&cursor) }
        if ts_tree_cursor_goto_first_child(&cursor) {
            repeat {
                let child = ts_tree_cursor_current_node(&cursor)
                guard ts_node_is_named(child) else { continue }   // the words themselves are unnamed tokens
                add(upTo: ts_node_start_byte(child), ts_node_start_point(child))
                startByte = ts_node_end_byte(child)
                startPoint = ts_node_end_point(child)
            } while ts_tree_cursor_goto_next_sibling(&cursor)
        }
        add(upTo: ts_node_end_byte(node), ts_node_end_point(node))
    }
}

/// Hands tree-sitter the text in chunks, copied out of the piece table into scratch memory.
private final class InputReader {
    let text: PieceTable
    let capacity = 64 * 1024
    let scratch: UnsafeMutablePointer<UInt8>

    init(text: PieceTable) {
        self.text = text
        scratch = .allocate(capacity: capacity)
    }

    deinit { scratch.deallocate() }

    func read(at offset: Int) -> Int {
        let end = min(text.count, offset + capacity)
        guard offset < end else { return 0 }
        var n = 0
        text.forEachChunk(in: offset..<end) { chunk in
            (scratch + n).update(from: chunk.baseAddress!, count: chunk.count)
            n += chunk.count
            return true
        }
        return n
    }
}

private let readCallback: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, TSPoint, UnsafeMutablePointer<UInt32>?
) -> UnsafePointer<CChar>? = { payload, byteIndex, _, bytesRead in
    let reader = Unmanaged<InputReader>.fromOpaque(payload!).takeUnretainedValue()
    let n = reader.read(at: Int(byteIndex))
    bytesRead?.pointee = UInt32(n)
    return UnsafeRawPointer(reader.scratch).assumingMemoryBound(to: CChar.self)
}
