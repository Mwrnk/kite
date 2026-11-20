import Foundation

/// A run of text inside a block, with its inline styling.
public struct MarkdownSpan: Equatable, Sendable {
    public struct Style: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let emphasis = Style(rawValue: 1)
        public static let strong = Style(rawValue: 2)
        public static let code = Style(rawValue: 4)
        public static let strikethrough = Style(rawValue: 8)
        /// Raw HTML, shown as text.
        public static let html = Style(rawValue: 16)
    }

    public var text: String
    public var style: Style
    /// Where the span links to, as written.
    public var link: String?
    /// An image's source, as written; `text` is its alt text.
    public var image: String?

    public init(text: String, style: Style = [], link: String? = nil, image: String? = nil) {
        self.text = text
        self.style = style
        self.link = link
        self.image = image
    }
}

public enum ListMarker: Equatable, Sendable {
    case bullet
    case number(Int)
    case task(done: Bool)
}

public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public var columns: [Alignment]
    /// One span list per cell.
    public var header: [[MarkdownSpan]]
    public var rows: [[[MarkdownSpan]]]
}

/// One block of the document: a heading, a paragraph, a code block, a table or a rule. List
/// items and quotes aren't blocks of their own; they're how deep a block sits.
public struct MarkdownBlock: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case heading(level: Int)
        case paragraph
        case codeBlock(language: String?)
        case table(MarkdownTable)
        case rule
    }

    public var kind: Kind
    /// The block's text; empty for tables and rules.
    public var spans: [MarkdownSpan]
    /// How many block quotes the block is inside.
    public var quoteDepth: Int
    /// How many lists the block is inside; 0 outside lists.
    public var listDepth: Int
    /// The list item's marker, on the first block of a list item only.
    public var marker: ListMarker?
    /// The source lines the block came from, counting from 0.
    public var lines: ClosedRange<Int>
}

/// A Markdown file as a list of blocks, each knowing which source lines it came from.
/// Parsing is Foundation's (CommonMark plus GitHub tables, strikethrough and task lists).
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    public static func parse(_ source: String) -> MarkdownDocument {
        var options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        options.appliesSourcePositionAttributes = true
        guard let parsed = try? AttributedString(markdown: source, options: options) else {
            let lastLine = max(source.split(separator: "\n", omittingEmptySubsequences: false).count - 1, 0)
            return MarkdownDocument(blocks: [MarkdownBlock(kind: .paragraph, spans: [MarkdownSpan(text: source)],
                                                           quoteDepth: 0, listDepth: 0, marker: nil, lines: 0...lastLine)])
        }
        var builder = Builder()
        for run in parsed.runs {
            builder.add(text: String(parsed[run.range].characters), intent: run.presentationIntent,
                        inline: run.inlinePresentationIntent ?? [], link: run.link, image: run.imageURL,
                        position: run.markdownSourcePosition)
        }
        return MarkdownDocument(blocks: builder.finish())
    }

    /// The block whose lines contain `line`, or else the last block starting before it.
    public func blockIndex(forLine line: Int) -> Int? {
        var found: Int?
        for (i, block) in blocks.enumerated() {
            if block.lines.lowerBound > line { break }
            found = i
        }
        return found
    }
}

/// Groups parsed runs into blocks.
private struct Builder {
    private var blocks: [MarkdownBlock] = []
    /// The identity of the innermost block component the last block came from.
    private var currentID: Int?
    /// Table cells collect here until the table ends.
    private var table: (id: Int, cells: [Int: (row: Int, column: Int, spans: [MarkdownSpan])], order: [Int])?
    private var seenListItems: Set<Int> = []

    mutating func add(text: String, intent: PresentationIntent?, inline: InlinePresentationIntent,
                      link: URL?, image: URL?, position: AttributedString.MarkdownSourcePosition?) {
        let lines = position.map { ($0.startLine - 1)...max($0.endLine - 1, $0.startLine - 1) }
        guard let intent, let innermost = intent.components.first else {
            // An HTML block comes with no block type at all. Keep it, as raw text.
            if inline.contains(.blockHTML) {
                var html = text
                while html.hasSuffix("\n") { html.removeLast() }
                blocks.append(MarkdownBlock(kind: .paragraph, spans: [MarkdownSpan(text: html, style: .html)],
                                            quoteDepth: 0, listDepth: 0, marker: nil, lines: lines ?? 0...0))
                currentID = nil
            }
            return
        }
        let span = Self.span(text: text, inline: inline, link: link, image: image, isCode: Self.isCodeBlock(innermost))

        // Tables: every cell's runs belong to one table block.
        if let tableComponent = intent.components.first(where: { if case .table = $0.kind { true } else { false } }) {
            addTableRun(span, intent: intent, table: tableComponent, lines: lines)
            return
        }

        if innermost.identity == currentID, !blocks.isEmpty {
            append(span, lines: lines)
            return
        }
        currentID = innermost.identity
        blocks.append(MarkdownBlock(kind: Self.kind(of: innermost), spans: [], quoteDepth: Self.count(.blockQuote, in: intent),
                                    listDepth: Self.listDepth(intent), marker: marker(intent), lines: lines ?? 0...0))
        if case .rule = blocks[blocks.count - 1].kind {} else { append(span, lines: nil) }
    }

    mutating func finish() -> [MarkdownBlock] {
        for i in blocks.indices {
            if case .codeBlock = blocks[i].kind, var last = blocks[i].spans.popLast() {
                if last.text.hasSuffix("\n") { last.text.removeLast() }
                if !last.text.isEmpty { blocks[i].spans.append(last) }
            }
            if blocks[i].marker == .bullet, var first = blocks[i].spans.first {
                for (prefix, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)] where first.text.hasPrefix(prefix) {
                    first.text.removeFirst(prefix.count)
                    blocks[i].marker = .task(done: done)
                    if first.text.isEmpty { blocks[i].spans.removeFirst() } else { blocks[i].spans[0] = first }
                    break
                }
            }
        }
        return blocks.filter { block in
            switch block.kind {
            case .rule, .table, .codeBlock: true
            default: !block.spans.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.image == nil }
            }
        }
    }

    // MARK: Pieces

    private mutating func append(_ span: MarkdownSpan, lines: ClosedRange<Int>?) {
        let i = blocks.count - 1
        if let lines { blocks[i].lines = Self.union(blocks[i].lines, lines) }
        Self.append(span, to: &blocks[i].spans)
    }

    private static func append(_ span: MarkdownSpan, to spans: inout [MarkdownSpan]) {
        if var last = spans.last, last.style == span.style, last.link == span.link, last.image == nil, span.image == nil {
            last.text += span.text
            spans[spans.count - 1] = last
        } else {
            spans.append(span)
        }
    }

    private mutating func addTableRun(_ span: MarkdownSpan, intent: PresentationIntent,
                                      table component: PresentationIntent.IntentType, lines: ClosedRange<Int>?) {
        guard case .table(let columns) = component.kind else { return }
        if table?.id != component.identity {
            table = (component.identity, [:], [])
            currentID = component.identity
            let alignments: [MarkdownTable.Alignment] = columns.map {
                switch $0.alignment { case .center: .center; case .right: .right; default: .left }
            }
            blocks.append(MarkdownBlock(kind: .table(MarkdownTable(columns: alignments, header: [], rows: [])), spans: [],
                                        quoteDepth: Self.count(.blockQuote, in: intent), listDepth: Self.listDepth(intent),
                                        marker: marker(intent), lines: lines ?? 0...0))
        }
        var row = 0, column = 0, cellID = component.identity
        for c in intent.components {
            switch c.kind {
            case .tableCell(let index): column = index; cellID = c.identity
            case .tableHeaderRow: row = 0
            case .tableRow(let index): row = index
            default: break
            }
        }
        if table!.cells[cellID] == nil {
            table!.cells[cellID] = (row, column, [])
            table!.order.append(cellID)
        }
        Self.append(span, to: &table!.cells[cellID]!.spans)

        // Rebuild the table block from the cells so far.
        let i = blocks.count - 1
        guard case .table(var t) = blocks[i].kind else { return }
        let cells = table!.order.map { table!.cells[$0]! }
        let rowCount = (cells.map(\.row).max() ?? 0) + 1
        func rowCells(_ r: Int) -> [[MarkdownSpan]] {
            let these = cells.filter { $0.row == r }
            let width = max(t.columns.count, (these.map(\.column).max() ?? -1) + 1)
            var out = Array(repeating: [MarkdownSpan](), count: width)
            for c in these { out[c.column] = c.spans }
            return out
        }
        t.header = rowCells(0)
        t.rows = rowCount > 1 ? (1..<rowCount).map(rowCells) : []
        blocks[i].kind = .table(t)
        if let lines { blocks[i].lines = Self.union(blocks[i].lines, lines) }
    }

    /// The marker for a block's list item, the first time that list item is seen.
    private mutating func marker(_ intent: PresentationIntent) -> ListMarker? {
        let components = intent.components
        guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
              case .listItem(let ordinal) = components[itemIndex].kind,
              seenListItems.insert(components[itemIndex].identity).inserted else { return nil }
        let list = components.indices.contains(itemIndex + 1) ? components[itemIndex + 1].kind : .unorderedList
        if case .orderedList = list { return .number(ordinal) }
        return .bullet
    }

    private static func kind(of component: PresentationIntent.IntentType) -> MarkdownBlock.Kind {
        switch component.kind {
        case .header(let level): .heading(level: level)
        case .codeBlock(let hint): .codeBlock(language: hint.flatMap { $0.isEmpty ? nil : $0 })
        case .thematicBreak: .rule
        default: .paragraph
        }
    }

    private static func isCodeBlock(_ component: PresentationIntent.IntentType) -> Bool {
        if case .codeBlock = component.kind { true } else { false }
    }

    private static func span(text: String, inline: InlinePresentationIntent, link: URL?, image: URL?, isCode: Bool) -> MarkdownSpan {
        var style: MarkdownSpan.Style = isCode ? .code : []
        if inline.contains(.emphasized) { style.insert(.emphasis) }
        if inline.contains(.stronglyEmphasized) { style.insert(.strong) }
        if inline.contains(.code) { style.insert(.code) }
        if inline.contains(.strikethrough) { style.insert(.strikethrough) }
        if inline.contains(.inlineHTML) || inline.contains(.blockHTML) { style.insert(.html) }
        let text = inline.contains(.lineBreak) ? "\n" : inline.contains(.softBreak) ? " " : text
        return MarkdownSpan(text: text, style: style, link: link?.relativeString, image: image?.relativeString)
    }

    private static func count(_ kind: PresentationIntent.Kind, in intent: PresentationIntent) -> Int {
        intent.components.filter { $0.kind == kind }.count
    }

    private static func listDepth(_ intent: PresentationIntent) -> Int {
        intent.components.filter { $0.kind == .orderedList || $0.kind == .unorderedList }.count
    }

    private static func union(_ a: ClosedRange<Int>, _ b: ClosedRange<Int>) -> ClosedRange<Int> {
        min(a.lowerBound, b.lowerBound)...max(a.upperBound, b.upperBound)
    }
}
