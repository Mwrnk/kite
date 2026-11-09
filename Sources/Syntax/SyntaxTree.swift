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
    }

    private func apply(_ edit: BufferEdit) {
        var e = TSInputEdit(
            start_byte: UInt32(edit.startByte), old_end_byte: UInt32(edit.oldEndByte),
            new_end_byte: UInt32(edit.newEndByte),
            start_point: TSPoint(edit.startPoint), old_end_point: TSPoint(edit.oldEndPoint),
            new_end_point: TSPoint(edit.newEndPoint))
        if let tree { ts_tree_edit(tree.pointer, &e) }
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
            for var e in editsDuringParse { ts_tree_edit(result.pointer, &e) }
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
        return query.run(on: ts_tree_root_node(tree.pointer), range: range, buffer: buffer)
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
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
    func copy() -> TreeBox { TreeBox(ts_tree_copy(pointer)) }
    deinit { ts_tree_delete(pointer) }
}

/// Owns the parser. Only used on `queue`.
final class ParseWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "kite.syntax.parse", qos: .userInitiated)
    private let parser: OpaquePointer

    init?(language: Language) {
        parser = ts_parser_new()
        guard ts_parser_set_language(parser, language.tsLanguage) else {
            ts_parser_delete(parser)
            return nil
        }
    }

    deinit { ts_parser_delete(parser) }

    func parse(_ text: PieceTable, old: TreeBox?) -> TreeBox? {
        let reader = InputReader(text: text)
        let input = TSInput(
            payload: Unmanaged.passUnretained(reader).toOpaque(),
            read: readCallback,
            encoding: TSInputEncodingUTF8,
            decode: nil)
        let result = withExtendedLifetime(reader) { ts_parser_parse(parser, old?.pointer, input) }
        return result.map(TreeBox.init)
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
