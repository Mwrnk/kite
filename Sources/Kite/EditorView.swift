import AppKit
import CoreText
import EditorCore
import Syntax

/// Draws the text with Core Text, one line at a time, and only the lines on screen.
/// All editing logic lives in `TextEditor`; this view turns keys and clicks into its commands.
final class EditorView: NSView, @preconcurrency NSTextInputClient, NSMenuItemValidation {
    let editor: TextEditor
    var syntax: SyntaxTree? {
        didSet {
            // Fresh colors arrive from the background parser; redraw with them.
            syntax?.onUpdate = { [weak self] in
                guard let self else { return }
                self.layoutCache.removeAll()
                self.spanWindow = nil
                self.bracketCache = nil
                self.needsDisplay = true
            }
            invalidateLayout()
        }
    }
    private(set) var theme: Theme = .dark

    /// Called after text or selection changes (status bar, dirty state, line numbers).
    var onChange: ((_ textChanged: Bool) -> Void)?

    // Metrics
    private(set) var font: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private(set) var lineHeight: CGFloat = 18
    private var ascent: CGFloat = 13
    private(set) var charWidth: CGFloat = 8
    let textInsetX: CGFloat = 12
    let textInsetY: CGFloat = 6

    // One laid-out line, plus how its UTF-8 byte columns map to UTF-16 (for Core Text).
    private struct LineLayout {
        let line: CTLine
        let utf16AtByte: [Int]?  // nil when the line is ASCII (byte == UTF-16 index)

        func utf16(_ byteColumn: Int) -> Int {
            guard let map = utf16AtByte else { return byteColumn }
            return map[min(byteColumn, map.count - 1)]
        }
        func byte(_ utf16Index: Int) -> Int {
            guard let map = utf16AtByte else { return utf16Index }
            var lo = 0, hi = map.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if map[mid] <= utf16Index { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
    }

    private var layoutCache: [Int: LineLayout] = [:]
    // Syntax colors for a window of lines; refetched when drawing moves outside it.
    private var spans: [HighlightSpan] = []
    private var spanWindow: Range<Int>?
    private var caretVisible = true
    // Soft wrap. Only row counts are kept for every line; break positions are worked out for
    // lines on screen and cached until the next edit.
    var wordWrap: Bool = UserDefaults.standard.bool(forKey: "wordWrap") {
        didSet { wrapColumns = 0; invalidateLayout(); scrollCaretIntoView() }
    }
    /// Wrapping is skipped for huge files, where measuring every line would slow things down.
    static let wrapLineLimit = 200_000
    var canWrap: Bool { editor.buffer.lineCount <= Self.wrapLineLimit }
    private var isWrapping: Bool { wordWrap && canWrap && wrapColumns > 0 && rowCounts.count == editor.buffer.lineCount }
    private var wrapColumns = 0                // characters per row
    private var rowCounts: [Int] = []          // rows in each line
    private var rowPrefix: [Int] = [0]         // rows before each line (count = lines + 1)
    private var breakCache: [Int: [Int]] = [:] // line → byte columns where rows 2, 3, … start
    private var goalX: CGFloat?                // keeps ↑/↓ in the same column across short rows
    private var keepGoalX = false

    // The bracket pair at the caret, cached per text version and caret position.
    private var bracketCache: (version: Int, caret: Int, pair: (Int, Int)?)?
    private var blinkTimer: Timer?

    /// Text to highlight everywhere it appears (set by the find bar).
    var findQuery = "" { didSet { needsDisplay = true } }
    var findCaseSensitive = false { didSet { needsDisplay = true } }

    init(editor: TextEditor) {
        self.editor = editor
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let size = UserDefaults.standard.double(forKey: "fontSize")
        setFontSize(size > 0 ? size : 13)
        editor.onChange = { [weak self] textChanged in self?.editorDidChange(textChanged: textChanged) }
        editor.buffer.addObserver { [weak self] edit in
            MainActor.assumeIsolated { self?.updateWrap(for: edit) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Metrics and layout

    func setFontSize(_ size: CGFloat) {
        font = .monospacedSystemFont(ofSize: min(max(size, 8), 40), weight: .regular)
        ascent = ceil(font.ascender)
        lineHeight = ceil((font.ascender - font.descender + font.leading) * 1.4)
        charWidth = font.advancement(forGlyph: font.glyph(withName: "M")).width
        if charWidth <= 0 { charWidth = font.maximumAdvancement.width }
        invalidateLayout()
    }

    private func invalidateLayout() {
        layoutCache.removeAll()
        spanWindow = nil
        updateFrameSize()
        needsDisplay = true
        (window?.windowController as? EditorWindowController)?.refreshGutter()
    }

    func updateFrameSize() {
        guard let scrollView = enclosingScrollView else { return }
        let visible = scrollView.contentSize
        if wordWrap && canWrap {
            let columns = max(Int((visible.width - textInsetX * 2) / charWidth) - 1, 20)
            if columns != wrapColumns || rowCounts.count != editor.buffer.lineCount {
                wrapColumns = columns
                rebuildWrap()
            }
        }
        let rows = isWrapping ? rowPrefix[rowPrefix.count - 1] : editor.buffer.lineCount
        let contentHeight = textInsetY + CGFloat(rows) * lineHeight
        // Let the last line scroll up to the middle of the window.
        let height = max(visible.height, contentHeight + visible.height / 2)
        let width = isWrapping ? visible.width
            : max(visible.width, textInsetX * 2 + CGFloat(editor.buffer.maxLineLength + 2) * charWidth)
        if frame.size != NSSize(width: width, height: height) {
            setFrameSize(NSSize(width: width, height: height))
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        theme = .forAppearance(effectiveAppearance)
        enclosingScrollView?.backgroundColor = NSColor(cgColor: theme.background) ?? .textBackgroundColor
        invalidateLayout()
    }

    func lineTop(_ line: Int) -> CGFloat {
        guard isWrapping else { return textInsetY + CGFloat(line) * lineHeight }
        return textInsetY + CGFloat(rowPrefix[min(max(line, 0), rowPrefix.count - 1)]) * lineHeight
    }

    /// Height of a whole line, all its wrapped rows included.
    func lineSpan(_ line: Int) -> CGFloat {
        isWrapping ? CGFloat(rowCounts[line]) * lineHeight : lineHeight
    }

    func line(atY y: CGFloat) -> Int {
        let row = Int(floor((y - textInsetY) / lineHeight))
        let last = editor.buffer.lineCount - 1
        guard isWrapping else { return min(max(row, 0), last) }
        // The last line whose first row is at or above `row`.
        var lo = 0, hi = last
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if rowPrefix[mid] <= row { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // MARK: Soft wrap

    private func rebuildWrap() {
        breakCache.removeAll()
        let count = editor.buffer.lineCount
        rowCounts = (0..<count).map { 1 + computeBreaks($0).count }
        rebuildRowPrefix()
    }

    private func rebuildRowPrefix() {
        var prefix = [Int](repeating: 0, count: rowCounts.count + 1)
        for i in rowCounts.indices { prefix[i + 1] = prefix[i] + rowCounts[i] }
        rowPrefix = prefix
    }

    /// Re-measures only the lines an edit touched.
    private func updateWrap(for edit: BufferEdit) {
        guard wordWrap, wrapColumns > 0, !rowCounts.isEmpty else { return }
        breakCache.removeAll()
        let oldLast = edit.oldEndPoint.row
        guard oldLast < rowCounts.count, canWrap else { rowCounts = []; return }
        let fresh = (edit.startPoint.row...edit.newEndPoint.row).map { 1 + computeBreaks($0).count }
        rowCounts.replaceSubrange(edit.startPoint.row...oldLast, with: fresh)
        if rowCounts.count != editor.buffer.lineCount { rebuildWrap() } else { rebuildRowPrefix() }
    }

    /// Byte columns where each wrapped row after the first begins. Breaks after the last space
    /// that fits, or mid-word when a word is longer than a row. Tabs and wide characters count
    /// as the columns they take up.
    private func computeBreaks(_ line: Int) -> [Int] {
        let buffer = editor.buffer
        let range = buffer.lineRange(line)
        let limit = wrapColumns
        let tabWidth = max(editor.settings.tabWidth, 1)
        if range.count * max(tabWidth, 2) <= limit { return [] }   // can't possibly overflow
        let bytes = buffer.bytes(in: range)
        let continuationLimit = limit - hangingIndent(line)
        var breaks: [Int] = []
        var lineCol = 0, rowStart = 0, rowStartCol = 0
        var spaceEnd = -1, spaceEndCol = 0
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            var length = 1, width = 1
            if b == 0x09 {
                width = tabWidth - lineCol % tabWidth
            } else if b >= 0xC0 {
                length = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : 2
                width = length >= 3 ? 2 : 1
            }
            if lineCol + width - rowStartCol > (breaks.isEmpty ? limit : continuationLimit) && i > rowStart {
                if spaceEnd > rowStart {
                    rowStart = spaceEnd; rowStartCol = spaceEndCol
                } else {
                    rowStart = i; rowStartCol = lineCol
                }
                breaks.append(rowStart)
                spaceEnd = -1
                continue   // look at this character again on the new row
            }
            lineCol += width
            i += length
            if b == 0x20 { spaceEnd = i; spaceEndCol = lineCol }
        }
        return breaks
    }

    /// Wrapped rows line up with the line's own indentation (capped at half a row), so they read
    /// as part of the same statement and don't sit on top of indent guides.
    private func hangingIndent(_ line: Int) -> Int {
        min(indentColumns(line) ?? 0, wrapColumns / 2)
    }

    /// Where a row's text starts, in points from the text edge.
    private func rowIndentX(_ line: Int, row: Int) -> CGFloat {
        row == 0 ? 0 : CGFloat(hangingIndent(line)) * charWidth
    }

    /// Byte columns where each row of a line starts (the first is always 0).
    private func rowStarts(_ line: Int) -> [Int] {
        guard isWrapping else { return [0] }
        if let cached = breakCache[line] { return cached }
        let starts = [0] + computeBreaks(line)
        breakCache[line] = starts
        return starts
    }

    /// Which row of its line a byte column is drawn on. A column exactly at a break starts the next row.
    private func row(ofColumn column: Int, starts: [Int]) -> Int {
        var r = 0
        while r + 1 < starts.count && starts[r + 1] <= column { r += 1 }
        return r
    }

    /// Top of the row that holds a byte offset.
    func rowTop(ofOffset offset: Int) -> CGFloat {
        let line = editor.buffer.line(containing: offset)
        guard isWrapping else { return lineTop(line) }
        let column = offset - editor.buffer.lineStarts[line]
        return lineTop(line) + CGFloat(row(ofColumn: column, starts: rowStarts(line))) * lineHeight
    }

    @objc func toggleWordWrap(_ sender: Any?) {
        wordWrap.toggle()
        UserDefaults.standard.set(wordWrap, forKey: "wordWrap")
    }

    var visibleLines: ClosedRange<Int> {
        line(atY: visibleRect.minY)...line(atY: visibleRect.maxY)
    }

    private func layout(_ line: Int) -> LineLayout {
        if let cached = layoutCache[line] { return cached }
        let buffer = editor.buffer
        let range = buffer.lineRange(line)
        let bytes = buffer.bytes(in: range)
        let string = String(decoding: bytes, as: UTF8.self)

        var map: [Int]?
        if bytes.contains(where: { $0 >= 0x80 }) {
            var m = [Int](repeating: 0, count: bytes.count + 1)
            var u = 0
            for (i, b) in bytes.enumerated() {
                m[i] = u
                if b & 0xC0 != 0x80 { u += b >= 0xF0 ? 2 : 1 }
            }
            m[bytes.count] = u
            map = m
        }
        func nsRange(_ r: Range<Int>) -> CFRange {
            let lo = map?[r.lowerBound] ?? r.lowerBound, hi = map?[r.upperBound] ?? r.upperBound
            return CFRange(location: lo, length: hi - lo)
        }

        let attributed = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(attributed, CFRange(location: 0, length: 0), string as CFString)
        let whole = CFRange(location: 0, length: CFAttributedStringGetLength(attributed))
        CFAttributedStringSetAttribute(attributed, whole, kCTFontAttributeName, font)
        CFAttributedStringSetAttribute(attributed, whole, kCTForegroundColorAttributeName, theme.text)
        CFAttributedStringSetAttribute(attributed, whole, kCTParagraphStyleAttributeName, tabStyle)

        // Syntax colors: spans come ordered so later ones paint over earlier ones.
        if syntax != nil {
            ensureSpans(around: line)
            for span in spans where span.range.overlaps(range) || (span.range.lowerBound == range.lowerBound && range.isEmpty) {
                let lo = max(span.range.lowerBound, range.lowerBound) - range.lowerBound
                let hi = min(span.range.upperBound, range.upperBound) - range.lowerBound
                guard lo < hi, let color = theme.tokens[span.kind] else { continue }
                CFAttributedStringSetAttribute(attributed, nsRange(lo..<hi), kCTForegroundColorAttributeName, color)
            }
        }
        // Underline text an input method is still composing.
        if let marked = editor.markedRange, marked.overlaps(range) {
            let lo = max(marked.lowerBound, range.lowerBound) - range.lowerBound
            let hi = min(marked.upperBound, range.upperBound) - range.lowerBound
            CFAttributedStringSetAttribute(attributed, nsRange(lo..<hi), kCTUnderlineStyleAttributeName,
                                           NSNumber(value: CTUnderlineStyle.single.rawValue))
        }

        let result = LineLayout(line: CTLineCreateWithAttributedString(attributed), utf16AtByte: map)
        layoutCache[line] = result
        return result
    }

    /// Makes sure `spans` holds syntax colors for a window of lines around `line`.
    private func ensureSpans(around line: Int) {
        guard let syntax else { return }
        let buffer = editor.buffer
        let range = buffer.lineRange(line)
        if let window = spanWindow, window.lowerBound <= range.lowerBound, range.upperBound <= window.upperBound { return }
        let lo = buffer.lineStarts[max(line - 150, 0)]
        let hi = buffer.lineRange(min(line + 150, buffer.lineCount - 1)).upperBound
        spans = syntax.highlights(in: lo..<hi)
        spanWindow = lo..<hi
    }

    private var tabStyle: CTParagraphStyle {
        var interval = charWidth * CGFloat(editor.settings.tabWidth)
        let stops: CFArray = [] as CFArray
        return withUnsafeBytes(of: &interval) { intervalPtr in
            withUnsafeBytes(of: stops) { stopsPtr in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size,
                                            value: intervalPtr.baseAddress!),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size,
                                            value: stopsPtr.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }

    /// X position of a byte offset within its line, in view coordinates.
    func x(ofOffset offset: Int) -> CGFloat {
        let line = editor.buffer.line(containing: offset)
        let column = offset - editor.buffer.lineStarts[line]
        let l = layout(line)
        var x = CTLineGetOffsetForStringIndex(l.line, l.utf16(column), nil)
        if isWrapping {
            let starts = rowStarts(line)
            let r = row(ofColumn: column, starts: starts)
            let start = starts[r]
            if start > 0 { x -= CTLineGetOffsetForStringIndex(l.line, l.utf16(start), nil) - rowIndentX(line, row: r) }
        }
        return textInsetX + x
    }

    func caretRect(for offset: Int) -> NSRect {
        NSRect(x: x(ofOffset: offset) - 1, y: rowTop(ofOffset: offset), width: 2, height: lineHeight)
    }

    /// The buffer offset closest to a point in view coordinates.
    func offset(at point: NSPoint) -> Int {
        let buffer = editor.buffer
        if point.y < textInsetY { return 0 }
        let lineIndex = line(atY: point.y)
        if point.y >= lineTop(buffer.lineCount) { return buffer.byteCount }
        let l = layout(lineIndex)
        let length = buffer.lineRange(lineIndex).count
        var rowLow = 0, rowHigh = length, shift: CGFloat = 0, lastRow = true
        if isWrapping {
            let starts = rowStarts(lineIndex)
            let r = min(max(Int((point.y - lineTop(lineIndex)) / lineHeight), 0), starts.count - 1)
            rowLow = starts[r]
            lastRow = r == starts.count - 1
            rowHigh = lastRow ? length : starts[r + 1]
            if rowLow > 0 { shift = CTLineGetOffsetForStringIndex(l.line, l.utf16(rowLow), nil) - rowIndentX(lineIndex, row: r) }
        }
        let utf16 = CTLineGetStringIndexForPosition(l.line, CGPoint(x: point.x - textInsetX + shift, y: 0))
        var column = min(max(l.byte(max(utf16, 0)), rowLow), rowHigh)
        // Snap to a whole character.
        let start = buffer.lineStarts[lineIndex]
        let chars = editor.characters(inLine: lineIndex)
        column = chars.first(where: { $0.end > column && $0.start < column }).map { $0.start } ?? column
        // Past the end of a wrapped row: stay on this row rather than jumping to the next.
        if !lastRow && column >= rowHigh, let previous = chars.last(where: { $0.start < rowHigh }) {
            column = previous.start
        }
        return start + min(column, length)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let buffer = editor.buffer
        ctx.setFillColor(theme.background)
        ctx.fill(dirtyRect)

        let first = line(atY: dirtyRect.minY), last = line(atY: dirtyRect.maxY)
        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true

        // Current line (with one cursor only; several would light up half the screen).
        if editor.selection.isEmpty && !editor.hasMultipleCursors {
            let current = buffer.line(containing: editor.caret)
            if (first...last).contains(current) {
                ctx.setFillColor(theme.currentLine)
                ctx.fill(CGRect(x: dirtyRect.minX, y: lineTop(current), width: dirtyRect.width, height: lineSpan(current)))
            }
        }

        // Find matches.
        if !findQuery.isEmpty {
            let visible = buffer.lineStarts[first]..<buffer.lineRange(last).upperBound
            ctx.setFillColor(theme.findMatch)
            for match in editor.matches(of: findQuery, in: visible, caseSensitive: findCaseSensitive) {
                fillRange(match, in: ctx, lines: first...last)
            }
        }

        // Selections.
        ctx.setFillColor(isFocused ? theme.selection : theme.inactiveSelection)
        for s in editor.allSelections where !s.isEmpty {
            fillRange(s.range, in: ctx, lines: first...last)
        }

        drawIndentGuides(ctx, lines: first...last)

        // Text.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let baseline = (lineHeight - (font.ascender - font.descender)) / 2 + ascent
        for lineIndex in first...last {
            let l = layout(lineIndex)
            let starts = rowStarts(lineIndex)
            if starts.count == 1 {
                ctx.textPosition = CGPoint(x: textInsetX, y: lineTop(lineIndex) + baseline)
                CTLineDraw(l.line, ctx)
                continue
            }
            // A wrapped line: draw the whole line once per row, shifted left and clipped to that row.
            for (r, start) in starts.enumerated() {
                let top = lineTop(lineIndex) + CGFloat(r) * lineHeight
                guard top + lineHeight >= dirtyRect.minY, top <= dirtyRect.maxY else { continue }
                let shift = start == 0 ? 0 : CTLineGetOffsetForStringIndex(l.line, l.utf16(start), nil)
                let end = r + 1 < starts.count ? CTLineGetOffsetForStringIndex(l.line, l.utf16(starts[r + 1]), nil) : .greatestFiniteMagnitude / 4
                ctx.saveGState()
                // Continuation rows start at the text edge, so the previous row's tail can't show in the margin.
                let indent = rowIndentX(lineIndex, row: r)
                let left: CGFloat = r == 0 ? 0 : textInsetX + indent - 1
                ctx.clip(to: CGRect(x: left, y: top, width: textInsetX + indent + end - shift - left, height: lineHeight))
                ctx.textPosition = CGPoint(x: textInsetX + indent - shift, y: top + baseline)
                CTLineDraw(l.line, ctx)
                ctx.restoreGState()
            }
        }

        // Matching brackets, outlined.
        if editor.selection.isEmpty, !editor.hasMultipleCursors, let (open, close) = bracketPairAtCaret() {
            ctx.setStrokeColor(theme.bracketMatch)
            ctx.setLineWidth(1)
            for offset in [open, close] where (first...last).contains(buffer.line(containing: offset)) {
                let rect = CGRect(x: x(ofOffset: offset), y: rowTop(ofOffset: offset) + 1, width: charWidth, height: lineHeight - 2)
                ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            }
        }

        // Carets.
        if isFocused && caretVisible || window == nil {
            ctx.setFillColor(theme.caret)
            for s in editor.allSelections where (first...last).contains(buffer.line(containing: s.head)) {
                ctx.fill(caretRect(for: s.head))
            }
        }
    }

    /// Faint vertical lines at each indent level, so nested blocks are easy to follow.
    /// Blank lines take the smaller indent of their neighbors, so guides run through them.
    private func drawIndentGuides(_ ctx: CGContext, lines: ClosedRange<Int>) {
        let tabWidth = max(editor.settings.tabWidth, 1)
        let step = CGFloat(tabWidth) * charWidth
        guard step > 0 else { return }
        ctx.setFillColor(theme.indentGuide)
        let scale = window?.backingScaleFactor ?? 2
        for line in lines {
            let columns = indentColumns(line) ?? blankLineIndent(line)
            let levels = columns / tabWidth
            guard levels > 0 else { continue }
            for level in 0..<levels {
                let x = (textInsetX + CGFloat(level) * step).rounded(.down) + 0.5 / scale
                ctx.fill(CGRect(x: x, y: lineTop(line), width: 1 / scale, height: lineSpan(line)))
            }
        }
    }

    /// Leading whitespace width in columns, or nil for a blank line.
    private func indentColumns(_ line: Int) -> Int? {
        let buffer = editor.buffer
        let range = buffer.lineRange(line)
        let tabWidth = max(editor.settings.tabWidth, 1)
        var columns = 0
        var i = range.lowerBound
        while i < range.upperBound && i - range.lowerBound < 400 {
            switch buffer.byte(at: i) {
            case UInt8(ascii: " "): columns += 1
            case UInt8(ascii: "\t"): columns += tabWidth - columns % tabWidth
            default: return columns
            }
            i += 1
        }
        return i == range.upperBound ? nil : columns
    }

    private func blankLineIndent(_ line: Int) -> Int {
        let count = editor.buffer.lineCount
        var above: Int?, below: Int?
        var i = line - 1
        while i >= max(0, line - 100), above == nil { above = indentColumns(i); i -= 1 }
        i = line + 1
        while i < min(count, line + 100), below == nil { below = indentColumns(i); i += 1 }
        return min(above ?? 0, below ?? 0)
    }

    /// The bracket pair touching the caret, ignoring brackets in strings and comments.
    private func bracketPairAtCaret() -> (Int, Int)? {
        let caret = editor.caret, version = editor.buffer.version
        if let cache = bracketCache, cache.version == version, cache.caret == caret { return cache.pair }
        var ignored: [Range<Int>] = []
        if syntax != nil {
            let line = editor.buffer.line(containing: caret)
            ensureSpans(around: line)
            ignored = spans.filter { $0.kind == .string || $0.kind == .comment }.map(\.range)
                .sorted { $0.lowerBound < $1.lowerBound }
        }
        // Binary search: the last string/comment starting at or before `offset`, then check it covers it.
        // (Spans can nest, e.g. an escape inside a string, so also check the one before.)
        let pair = editor.bracketPair(near: caret) { offset in
            var lo = 0, hi = ignored.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ignored[mid].lowerBound <= offset { lo = mid + 1 } else { hi = mid }
            }
            return (max(0, lo - 2)..<lo).contains { ignored[$0].contains(offset) }
        }
        bracketCache = (version, caret, pair)
        return pair
    }

    /// Fills the area covered by a byte range, line by line. Line breaks show as a small extra width.
    private func fillRange(_ range: Range<Int>, in ctx: CGContext, lines: ClosedRange<Int>) {
        let buffer = editor.buffer
        let firstLine = max(buffer.line(containing: range.lowerBound), lines.lowerBound)
        let lastLine = min(buffer.line(containing: range.upperBound), lines.upperBound)
        guard firstLine <= lastLine else { return }
        for lineIndex in firstLine...lastLine {
            let lineRange = buffer.lineRange(lineIndex)
            let lo = max(range.lowerBound, lineRange.lowerBound)
            let hi = min(range.upperBound, lineRange.upperBound)
            let starts = rowStarts(lineIndex)
            if starts.count == 1 {
                let x0 = x(ofOffset: lo)
                var x1 = x(ofOffset: hi)
                if range.upperBound > lineRange.upperBound { x1 += charWidth * 0.6 }
                ctx.fill(CGRect(x: x0, y: lineTop(lineIndex), width: max(x1 - x0, 0), height: lineHeight))
                continue
            }
            // Wrapped: fill each row's share separately.
            let l = layout(lineIndex)
            let hang = rowIndentX(lineIndex, row: 1)
            func xAt(_ column: Int, rowStart: Int) -> CGFloat {
                textInsetX + CTLineGetOffsetForStringIndex(l.line, l.utf16(column), nil)
                    - (rowStart == 0 ? 0 : CTLineGetOffsetForStringIndex(l.line, l.utf16(rowStart), nil) - hang)
            }
            for (r, start) in starts.enumerated() {
                let isLast = r == starts.count - 1
                let rowLo = lineRange.lowerBound + start
                let rowHi = isLast ? lineRange.upperBound : lineRange.lowerBound + starts[r + 1]
                let a = max(lo, rowLo), b = min(hi, rowHi)
                guard a < b || (isLast && a == b && range.upperBound > lineRange.upperBound && a == rowHi) else { continue }
                let x0 = xAt(a - lineRange.lowerBound, rowStart: start)
                var x1 = xAt(b - lineRange.lowerBound, rowStart: start)
                if isLast && range.upperBound > lineRange.upperBound { x1 += charWidth * 0.6 }
                ctx.fill(CGRect(x: x0, y: lineTop(lineIndex) + CGFloat(r) * lineHeight, width: max(x1 - x0, 0), height: lineHeight))
            }
        }
    }

    // MARK: Reacting to edits

    private func editorDidChange(textChanged: Bool) {
        if !keepGoalX { goalX = nil }
        if textChanged {
            layoutCache.removeAll()
            spanWindow = nil
            updateFrameSize()
        }
        restartBlink()
        scrollCaretIntoView()
        needsDisplay = true
        inputContext?.invalidateCharacterCoordinates()
        onChange?(textChanged)
    }

    func scrollCaretIntoView() {
        let rect = caretRect(for: editor.caret).insetBy(dx: -charWidth * 4, dy: -lineHeight)
        scrollToVisible(rect)
    }

    // MARK: Caret blink

    private func restartBlink() {
        caretVisible = true
        blinkTimer?.invalidate()
        guard window != nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.caretVisible.toggle()
                if self.editor.hasMultipleCursors {
                    self.needsDisplay = true
                } else {
                    self.setNeedsDisplay(self.caretRect(for: self.editor.caret).insetBy(dx: -2, dy: 0))
                }
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        restartBlink(); needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        blinkTimer?.invalidate(); needsDisplay = true
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { blinkTimer?.invalidate() }
        theme = .forAppearance(effectiveAppearance)
    }

    // MARK: Mouse

    override func resetCursorRects() { addCursorRect(visibleRect, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let offset = self.offset(at: point)
        // ⌥-click adds a cursor (or removes the one clicked).
        if event.modifierFlags.contains(.option) && event.clickCount == 1 {
            editor.addSelection(Selection(caret: offset))
            return
        }
        switch event.clickCount {
        case 2: editor.selectWord(at: offset)
        case 3: editor.selectLine(at: offset)
        default:
            if event.modifierFlags.contains(.shift) {
                editor.setSelection(Selection(anchor: editor.selection.anchor, head: offset))
            } else {
                editor.setSelection(Selection(caret: offset))
            }
        }
        let anchor = editor.selection.anchor
        // Track the drag until the button comes up.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            autoscroll(with: next)
            let head = self.offset(at: convert(next.locationInWindow, from: nil))
            editor.setSelection(Selection(anchor: anchor, head: head))
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        NSCursor.setHiddenUntilMouseMoves(true)
        interpretKeyEvents([event])
    }

    private var pageLines: Int { max(Int(visibleRect.height / lineHeight) - 2, 1) }

    override func doCommand(by selector: Selector) {
        let e = editor
        switch NSStringFromSelector(selector) {
        case "moveLeft:", "moveBackward:": e.move(.left)
        case "moveRight:", "moveForward:": e.move(.right)
        case "moveUp:": isWrapping && !e.hasMultipleCursors ? moveByRow(-1, extend: false) : e.move(.up)
        case "moveDown:": isWrapping && !e.hasMultipleCursors ? moveByRow(1, extend: false) : e.move(.down)
        case "moveWordLeft:", "moveWordBackward:": e.move(.wordLeft)
        case "moveWordRight:", "moveWordForward:": e.move(.wordRight)
        case "moveToLeftEndOfLine:", "moveToBeginningOfLine:", "moveToBeginningOfParagraph:": e.move(.lineStart)
        case "moveToRightEndOfLine:", "moveToEndOfLine:", "moveToEndOfParagraph:": e.move(.lineEnd)
        case "moveToBeginningOfDocument:": e.move(.documentStart)
        case "moveToEndOfDocument:": e.move(.documentEnd)
        case "pageUp:", "scrollPageUp:": e.move(.pageUp(lines: pageLines))
        case "pageDown:", "scrollPageDown:": e.move(.pageDown(lines: pageLines))

        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:": e.move(.left, extend: true)
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:": e.move(.right, extend: true)
        case "moveUpAndModifySelection:": isWrapping && !e.hasMultipleCursors ? moveByRow(-1, extend: true) : e.move(.up, extend: true)
        case "moveDownAndModifySelection:": isWrapping && !e.hasMultipleCursors ? moveByRow(1, extend: true) : e.move(.down, extend: true)
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:": e.move(.wordLeft, extend: true)
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:": e.move(.wordRight, extend: true)
        case "moveToLeftEndOfLineAndModifySelection:", "moveToBeginningOfLineAndModifySelection:",
             "moveParagraphBackwardAndModifySelection:": e.move(.lineStart, extend: true)
        case "moveToRightEndOfLineAndModifySelection:", "moveToEndOfLineAndModifySelection:",
             "moveParagraphForwardAndModifySelection:": e.move(.lineEnd, extend: true)
        case "moveToBeginningOfDocumentAndModifySelection:": e.move(.documentStart, extend: true)
        case "moveToEndOfDocumentAndModifySelection:": e.move(.documentEnd, extend: true)
        case "pageUpAndModifySelection:": e.move(.pageUp(lines: pageLines), extend: true)
        case "pageDownAndModifySelection:": e.move(.pageDown(lines: pageLines), extend: true)
        case "scrollToBeginningOfDocument:": scroll(.zero)
        case "scrollToEndOfDocument:": scroll(NSPoint(x: 0, y: lineTop(editor.buffer.lineCount)))

        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:": e.insertNewline()
        case "insertTab:", "insertTabIgnoringFieldEditor:": e.insertTab()
        case "insertBacktab:": e.outdentLines()
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:": e.deleteBackward()
        case "deleteForward:": e.deleteForward()
        case "deleteWordBackward:": e.deleteWordBackward()
        case "deleteWordForward:": e.deleteWordForward()
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:": e.deleteToLineStart()
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":
            let end = e.buffer.lineRange(e.buffer.line(containing: e.caret)).upperBound
            e.setSelection(Selection(anchor: e.caret, head: end == e.caret ? e.nextCharacterBoundary(end) : end))
            e.deleteForward()
        case "cancelOperation:":
            if e.hasMultipleCursors {
                e.collapseToMainCursor()
            } else if let controller = window?.windowController as? EditorWindowController, controller.isFindBarVisible {
                controller.hideFindBar()
            } else if !e.selection.isEmpty {
                e.setSelection(Selection(caret: e.caret))
            }
        default:
            break  // unknown commands are ignored rather than beeping
        }
    }

    /// ↑/↓ with soft wrap on: move one screen row, keeping the same horizontal position.
    private func moveByRow(_ direction: Int, extend: Bool) {
        let e = editor
        let caret = caretRect(for: e.selection.head)
        let x = goalX ?? caret.midX
        let y = caret.midY + CGFloat(direction) * lineHeight
        let target: Int
        if y < textInsetY { target = 0 }
        else if y >= lineTop(e.buffer.lineCount) { target = e.buffer.byteCount }
        else { target = offset(at: NSPoint(x: x, y: y)) }
        keepGoalX = true
        e.setSelection(extend ? Selection(anchor: e.selection.anchor, head: target) : Selection(caret: target))
        keepGoalX = false
        goalX = x
    }

    // MARK: Menu actions (reached through the responder chain)

    @objc func undo(_ sender: Any?) { editor.undo() }
    @objc func redo(_ sender: Any?) { editor.redo() }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(editor.textToCopy(), forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        let text = editor.cut()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        editor.replaceSelection(with: text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    override func selectAll(_ sender: Any?) { editor.selectAll() }
    @objc func toggleComment(_ sender: Any?) { editor.toggleComment() }
    @objc func indentLines(_ sender: Any?) { editor.indentLines() }
    @objc func outdentLines(_ sender: Any?) { editor.outdentLines() }
    @objc func moveLineUp(_ sender: Any?) { editor.moveLines(by: -1) }
    @objc func addNextOccurrence(_ sender: Any?) { editor.addNextOccurrence() }
    @objc func splitSelectionIntoLines(_ sender: Any?) { editor.splitSelectionIntoLines() }
    @objc func addCursorAbove(_ sender: Any?) { editor.addCursorVertically(-1) }
    @objc func addCursorBelow(_ sender: Any?) { editor.addCursorVertically(1) }
    @objc func moveLineDown(_ sender: Any?) { editor.moveLines(by: 1) }

    @objc func zoomIn(_ sender: Any?) { changeFontSize(by: 1) }
    @objc func zoomOut(_ sender: Any?) { changeFontSize(by: -1) }
    @objc func resetZoom(_ sender: Any?) { changeFontSize(by: 13 - font.pointSize) }

    private func changeFontSize(by delta: CGFloat) {
        let caret = editor.caret
        setFontSize(font.pointSize + delta)
        UserDefaults.standard.set(font.pointSize, forKey: "fontSize")
        scrollToVisible(caretRect(for: caret))
    }

    @objc func goToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number (1–\(editor.buffer.lineCount)), or line:column."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let line = parts.first else { return }
            let row = min(max(line - 1, 0), self.editor.buffer.lineCount - 1)
            let column = parts.count > 1 ? max(parts[1] - 1, 0) : 0
            let target = self.editor.offset(inLine: row, displayColumn: column)
            self.editor.setSelection(Selection(caret: target))
            self.scrollToVisible(NSRect(x: 0, y: self.lineTop(row) - self.visibleRect.height / 3,
                                        width: 1, height: self.visibleRect.height * 2 / 3))
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return editor.canUndo
        case #selector(redo(_:)): return editor.canRedo
        case #selector(paste(_:)): return NSPasteboard.general.string(forType: .string) != nil
        case #selector(toggleComment(_:)): return editor.settings.lineComment != nil
        case #selector(toggleWordWrap(_:)):
            item.state = wordWrap ? .on : .off
            return canWrap
        default: return true
        }
    }

    // MARK: NSTextInputClient (typing, input methods, dictation)

    private func string(from value: Any) -> String {
        (value as? NSAttributedString)?.string ?? (value as? String) ?? ""
    }

    private func byteRange(_ range: NSRange) -> Range<Int> {
        let b = editor.buffer
        let lo = b.byteOffset(ofUTF16: range.location)
        return lo..<max(lo, b.byteOffset(ofUTF16: range.location + range.length))
    }

    private func utf16Range(_ range: Range<Int>) -> NSRange {
        let lo = editor.buffer.utf16Offset(ofByte: range.lowerBound)
        return NSRange(location: lo, length: editor.buffer.utf16Offset(ofByte: range.upperBound) - lo)
    }

    func insertText(_ value: Any, replacementRange: NSRange) {
        let text = string(from: value)
        if replacementRange.location != NSNotFound, editor.markedRange == nil {
            let r = byteRange(replacementRange)
            editor.setSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
        }
        editor.insertText(text)
    }

    func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = string(from: value)
        if replacementRange.location != NSNotFound, editor.markedRange == nil {
            let r = byteRange(replacementRange)
            editor.setSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
        }
        // selectedRange is UTF-16 within the marked text; convert to UTF-8 bytes.
        let utf16 = Array(text.utf16)
        func bytes(_ u: Int) -> Int {
            String(decoding: utf16[..<min(u, utf16.count)], as: UTF16.self).utf8.count
        }
        editor.setMarkedText(text, selectedRange: bytes(selectedRange.location)..<bytes(selectedRange.location + selectedRange.length))
    }

    func unmarkText() {
        editor.commitMarkedText()
        layoutCache.removeAll()
        needsDisplay = true
    }

    func selectedRange() -> NSRange { utf16Range(editor.selection.range) }

    func markedRange() -> NSRange {
        editor.markedRange.map(utf16Range) ?? NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool { editor.markedRange != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let r = byteRange(range)
        let clamped = r.lowerBound..<min(r.upperBound, r.lowerBound + 10_000, editor.buffer.byteCount)
        actualRange?.pointee = utf16Range(clamped)
        return NSAttributedString(string: editor.buffer.string(in: clamped), attributes: [.font: font])
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let r = byteRange(range)
        let lineEnd = editor.buffer.lineRange(editor.buffer.line(containing: r.lowerBound)).upperBound
        let end = min(r.upperBound, lineEnd)
        actualRange?.pointee = utf16Range(r.lowerBound..<end)
        var rect = caretRect(for: r.lowerBound)
        rect.size.width = max(x(ofOffset: end) - rect.minX, 1)
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for screenPoint: NSPoint) -> Int {
        guard let window else { return NSNotFound }
        let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return editor.buffer.utf16Offset(ofByte: offset(at: point))
    }
}
