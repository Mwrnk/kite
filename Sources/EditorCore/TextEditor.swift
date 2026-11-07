import Foundation

public struct Selection: Equatable, Sendable {
    /// Where the selection started (stays put while extending).
    public var anchor: Int
    /// Where the caret is.
    public var head: Int

    public init(anchor: Int, head: Int) { self.anchor = anchor; self.head = head }
    public init(caret: Int) { self.init(anchor: caret, head: caret) }

    public var range: Range<Int> { min(anchor, head)..<max(anchor, head) }
    public var isEmpty: Bool { anchor == head }
}

public struct EditorSettings: Equatable, Sendable {
    public var tabWidth = 4
    public var insertSpaces = true
    public var autoCloseBrackets = true
    /// Line comment token for the current language, e.g. "//" or "#".
    public var lineComment: String? = "//"

    public init() {}

    public var indentUnit: String { insertSpaces ? String(repeating: " ", count: tabWidth) : "\t" }
}

public enum Movement: Sendable {
    case left, right, wordLeft, wordRight
    case lineStart, lineEnd
    case up, down
    case pageUp(lines: Int), pageDown(lines: Int)
    case documentStart, documentEnd
}

/// The editing model: a buffer, a selection and every editing command, with undo.
/// Knows nothing about drawing, so it can be tested without a window.
public final class TextEditor {
    public let buffer: TextBuffer
    public var settings: EditorSettings
    /// The main selection: the one the view scrolls to and input methods use.
    public private(set) var selection = Selection(caret: 0)
    /// More cursors, from ⌥-click, ⌘D and friends. Every editing command runs at each one.
    public private(set) var extraSelections: [Selection] = []
    /// Text being composed by an input method (e.g. Japanese, accents). Lives in the buffer.
    public private(set) var markedRange: Range<Int>?

    /// Called after any change to text or selection.
    public var onChange: ((_ textChanged: Bool) -> Void)?

    public init(buffer: TextBuffer = TextBuffer(), settings: EditorSettings = EditorSettings()) {
        self.buffer = buffer
        self.settings = settings
    }

    public convenience init(_ text: String) { self.init(buffer: TextBuffer(text)) }

    public var text: String { buffer.string }
    public var caret: Int { selection.head }
    public var selectedText: String { buffer.string(in: selection.range) }
    public var hasMultipleCursors: Bool { !extraSelections.isEmpty }
    /// Every selection, in document order.
    public var allSelections: [Selection] {
        ([selection] + extraSelections).sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Undo

    private struct EditRecord {
        var start: Int
        var oldBytes: [UInt8]
        var newBytes: [UInt8]
    }

    private enum StepKind { case typing, deleting, other }

    private struct UndoStep {
        var id: Int
        var kind: StepKind
        var edits: [EditRecord]
        var selectionBefore: Selection
        var selectionAfter: Selection
        var extrasBefore: [Selection] = []
        var extrasAfter: [Selection] = []
    }

    private var undoStack: [UndoStep] = []
    private var redoStack: [UndoStep] = []
    private var nextStepID = 1
    private var savedStepID = 0
    private var canCoalesce = false
    /// Collects edits while one command runs at several cursors, so they become one undo step.
    private var batch: [EditRecord]?

    /// Reports a change, except in the middle of a multi-cursor command (which reports once at the end).
    private func changed(_ textChanged: Bool) {
        if batch == nil { onChange?(textChanged) }
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    /// True when the text differs from the last save.
    public var isDirty: Bool { (undoStack.last?.id ?? 0) != savedStepID }

    /// Replaces all text (e.g. File ▸ Revert) and starts a fresh undo history.
    public func resetText(_ text: String) {
        markedRange = nil
        markedOriginal = nil
        buffer.replace(0..<buffer.byteCount, with: text)
        undoStack.removeAll()
        redoStack.removeAll()
        savedStepID = 0
        canCoalesce = false
        goalColumn = nil
        selection = clamp(selection)
        extraSelections = []
        onChange?(true)
    }

    public func markSaved() {
        savedStepID = undoStack.last?.id ?? 0
        canCoalesce = false
    }

    public func undo() {
        commitMarkedText()
        guard let step = undoStack.popLast() else { return }
        for edit in step.edits.reversed() {
            buffer.replace(edit.start..<(edit.start + edit.newBytes.count), withBytes: edit.oldBytes)
        }
        selection = step.selectionBefore
        extraSelections = step.extrasBefore
        redoStack.append(step)
        canCoalesce = false
        goalColumn = nil
        onChange?(true)
    }

    public func redo() {
        guard let step = redoStack.popLast() else { return }
        for edit in step.edits {
            buffer.replace(edit.start..<(edit.start + edit.oldBytes.count), withBytes: edit.newBytes)
        }
        selection = step.selectionAfter
        extraSelections = step.extrasAfter
        undoStack.append(step)
        canCoalesce = false
        goalColumn = nil
        onChange?(true)
    }

    /// Applies replacements given in current-document offsets as one undo step.
    /// Edits must not overlap; they are applied back to front so offsets stay valid.
    private func transact(_ kind: StepKind, _ replacements: [(Range<Int>, String)], selectAfter: Selection,
                          extrasAfter: [Selection]? = nil) {
        let before = selection, extrasBefore = extraSelections
        var records: [EditRecord] = []
        for (range, text) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            let old = buffer.bytes(in: range)
            let new = Array(text.utf8)
            if old == new { continue }
            buffer.replace(range, withBytes: new)
            records.append(EditRecord(start: range.lowerBound, oldBytes: old, newBytes: new))
        }
        selection = clamp(selectAfter)
        if let extrasAfter { extraSelections = extrasAfter.map(clamp) }
        goalColumn = nil
        if batch != nil { batch!.append(contentsOf: records); return }
        guard !records.isEmpty else { onChange?(false); return }
        redoStack.removeAll()

        if canCoalesce, kind != .other, let last = undoStack.last, last.kind == kind,
           records.count == 1, shouldCoalesce(records[0], into: last) {
            undoStack[undoStack.count - 1].edits.append(records[0])
            undoStack[undoStack.count - 1].selectionAfter = selection
        } else {
            undoStack.append(UndoStep(id: nextStepID, kind: kind, edits: records,
                                      selectionBefore: before, selectionAfter: selection,
                                      extrasBefore: extrasBefore, extrasAfter: extraSelections))
            nextStepID += 1
        }
        canCoalesce = kind != .other && extraSelections.isEmpty
        onChange?(true)
    }

    private func shouldCoalesce(_ edit: EditRecord, into step: UndoStep) -> Bool {
        guard let prev = step.edits.last else { return false }
        switch step.kind {
        case .typing:
            // Keep typing in one step until a newline or a word break after a space.
            let typedSpace = prev.newBytes.last == 0x20 && edit.newBytes.first != 0x20
            return edit.oldBytes.isEmpty && edit.start == prev.start + prev.newBytes.count
                && !edit.newBytes.contains(0x0A) && !typedSpace
        case .deleting:
            return edit.newBytes.isEmpty && edit.start + edit.oldBytes.count == prev.start
                && !edit.oldBytes.contains(0x0A)
        case .other:
            return false
        }
    }

    // MARK: Selection

    private var goalColumn: Int?

    private func clamp(_ s: Selection) -> Selection {
        Selection(anchor: min(max(s.anchor, 0), buffer.byteCount), head: min(max(s.head, 0), buffer.byteCount))
    }

    public func setSelection(_ s: Selection) {
        commitMarkedText()
        selection = clamp(s)
        extraSelections = []
        goalColumn = nil
        canCoalesce = false
        onChange?(false)
    }

    public func selectAll() { setSelection(Selection(anchor: 0, head: buffer.byteCount)) }

    public func move(_ movement: Movement, extend: Bool = false) {
        if hasMultipleCursors && batch == nil {
            atEachCursor { _ in self.move(movement, extend: extend) }
            return
        }
        commitMarkedText()
        let keepGoal: Bool
        var head = selection.head
        switch movement {
        case .left where !extend && !selection.isEmpty: head = selection.range.lowerBound; keepGoal = false
        case .right where !extend && !selection.isEmpty: head = selection.range.upperBound; keepGoal = false
        case .left: head = previousCharacterBoundary(head); keepGoal = false
        case .right: head = nextCharacterBoundary(head); keepGoal = false
        case .wordLeft: head = previousWordBoundary(head); keepGoal = false
        case .wordRight: head = nextWordBoundary(head); keepGoal = false
        case .lineStart: head = smartLineStart(head); keepGoal = false
        case .lineEnd: head = buffer.lineRange(buffer.line(containing: head)).upperBound; keepGoal = false
        case .up: head = verticalTarget(from: head, lines: -1); keepGoal = true
        case .down: head = verticalTarget(from: head, lines: 1); keepGoal = true
        case .pageUp(let n): head = verticalTarget(from: head, lines: -max(n, 1)); keepGoal = true
        case .pageDown(let n): head = verticalTarget(from: head, lines: max(n, 1)); keepGoal = true
        case .documentStart: head = 0; keepGoal = false
        case .documentEnd: head = buffer.byteCount; keepGoal = false
        }
        let goal = goalColumn
        selection = extend ? Selection(anchor: selection.anchor, head: head) : Selection(caret: head)
        goalColumn = keepGoal ? goal : nil
        canCoalesce = false
        changed(false)
    }

    public func selectWord(at offset: Int) {
        let line = buffer.line(containing: offset)
        let range = buffer.lineRange(line)
        let chars = characters(inLine: line)
        let col = offset - range.lowerBound
        guard let index = chars.firstIndex(where: { $0.end > col }) ?? chars.indices.last else {
            setSelection(Selection(caret: offset)); return
        }
        let kind = Self.kind(of: chars[index].char)
        var lo = index, hi = index
        while lo > 0, Self.kind(of: chars[lo - 1].char) == kind { lo -= 1 }
        while hi + 1 < chars.count, Self.kind(of: chars[hi + 1].char) == kind { hi += 1 }
        setSelection(Selection(anchor: range.lowerBound + chars[lo].start, head: range.lowerBound + chars[hi].end))
    }

    public func selectLine(at offset: Int) {
        let line = buffer.line(containing: offset)
        let start = buffer.lineStarts[line]
        let end = line + 1 < buffer.lineCount ? buffer.lineStarts[line + 1] : buffer.byteCount
        setSelection(Selection(anchor: start, head: end))
    }

    // MARK: Multiple cursors

    /// Runs a single-cursor command at every cursor, last one first so earlier edits don't move
    /// positions still to be handled, and records it all as one undo step. The closure gets the
    /// cursor's index in document order.
    private func atEachCursor(_ command: (Int) -> Void) {
        commitMarkedText()
        let primaryBefore = selection, extrasBefore = extraSelections
        let ordered = ([selection] + extraSelections).enumerated()
            .sorted { $0.element.range.lowerBound < $1.element.range.lowerBound }
        batch = []
        var done: [(isPrimary: Bool, selection: Selection)] = []
        for (docIndex, entry) in ordered.enumerated().reversed() {
            let sizeBefore = buffer.byteCount
            selection = entry.element
            goalColumn = nil
            command(docIndex)
            // Cursors already handled sit further down; this cursor's edit moved them.
            let delta = buffer.byteCount - sizeBefore
            if delta != 0 {
                for k in done.indices {
                    done[k].selection = Selection(anchor: done[k].selection.anchor + delta, head: done[k].selection.head + delta)
                }
            }
            done.append((entry.offset == 0, selection))
        }
        let records = batch ?? []
        batch = nil
        selection = clamp(done.first(where: \.isPrimary)!.selection)
        extraSelections = done.filter { !$0.isPrimary }.map { clamp($0.selection) }
        mergeOverlappingSelections()
        goalColumn = nil
        canCoalesce = false
        guard !records.isEmpty else { onChange?(false); return }
        redoStack.removeAll()
        undoStack.append(UndoStep(id: nextStepID, kind: .other, edits: records,
                                  selectionBefore: primaryBefore, selectionAfter: selection,
                                  extrasBefore: extrasBefore, extrasAfter: extraSelections))
        nextStepID += 1
        onChange?(true)
    }

    /// Cursors that ended up touching or overlapping become one.
    private func mergeOverlappingSelections() {
        guard hasMultipleCursors else { return }
        var merged: [(Selection, isPrimary: Bool)] = []
        for (s, isPrimary) in (([(selection, true)] + extraSelections.map { ($0, false) })
                                .sorted { $0.0.range.lowerBound < $1.0.range.lowerBound }) {
            let overlaps = merged.last.map { s.range.lowerBound < $0.0.range.upperBound } ?? false
            let sameCaret = merged.last.map { s.isEmpty && $0.0.isEmpty && s.head == $0.0.head } ?? false
            if let last = merged.last, overlaps || sameCaret {
                let r = min(last.0.range.lowerBound, s.range.lowerBound)..<max(last.0.range.upperBound, s.range.upperBound)
                let forward = (isPrimary ? s : last.0).head >= (isPrimary ? s : last.0).anchor
                merged[merged.count - 1] = (forward ? Selection(anchor: r.lowerBound, head: r.upperBound)
                                                    : Selection(anchor: r.upperBound, head: r.lowerBound), isPrimary || last.1)
            } else {
                merged.append((s, isPrimary))
            }
        }
        selection = merged.first(where: \.isPrimary)?.0 ?? merged.last!.0
        extraSelections = merged.filter { !$0.isPrimary }.map(\.0)
    }

    /// Adds a cursor or selection (⌥-click). It becomes the main one. ⌥-clicking an existing cursor removes it.
    public func addSelection(_ s: Selection) {
        commitMarkedText()
        let s = clamp(s)
        if s.isEmpty, hasMultipleCursors, let i = extraSelections.firstIndex(where: { $0.isEmpty && $0.head == s.head }) {
            extraSelections.remove(at: i)
        } else if s.isEmpty, hasMultipleCursors, selection.isEmpty, selection.head == s.head {
            selection = extraSelections.removeLast()
        } else {
            extraSelections.append(selection)
            selection = s
            mergeOverlappingSelections()
        }
        goalColumn = nil
        canCoalesce = false
        onChange?(false)
    }

    /// Back to one cursor (Esc).
    public func collapseToMainCursor() {
        guard hasMultipleCursors else { return }
        extraSelections = []
        onChange?(false)
    }

    /// ⌘D: selects the word at the cursor; pressed again, adds the next match of the selection.
    public func addNextOccurrence() {
        if selection.isEmpty {
            let keep = extraSelections
            selectWord(at: selection.head)
            if !keep.isEmpty { extraSelections = keep; mergeOverlappingSelections(); onChange?(false) }
            return
        }
        let needle = selectedText
        guard let r = find(needle, from: selection.range.upperBound, caseSensitive: true),
              !allSelections.contains(where: { $0.range == r }) else { return }   // every match already selected
        addSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
    }

    /// ⇧⌘L: one cursor per line of the selection, each selecting its part of the line.
    public func splitSelectionIntoLines() {
        let r = selection.range
        let lines = selectedLines
        guard lines.count > 1 else { return }
        var pieces: [Selection] = []
        for line in lines {
            let range = buffer.lineRange(line)
            pieces.append(Selection(anchor: max(range.lowerBound, r.lowerBound), head: min(range.upperBound, r.upperBound)))
        }
        selection = pieces.removeLast()
        extraSelections += pieces
        mergeOverlappingSelections()
        canCoalesce = false
        onChange?(false)
    }

    /// ⌥⌘↑ / ⌥⌘↓: adds a cursor on the line above the topmost cursor (or below the bottom one).
    public func addCursorVertically(_ direction: Int) {
        let edge = direction < 0 ? allSelections.first! : allSelections.last!
        let line = buffer.line(containing: edge.head) + (direction < 0 ? -1 : 1)
        guard line >= 0, line < buffer.lineCount else { return }
        addSelection(Selection(caret: offset(inLine: line, displayColumn: displayColumn(of: edge.head))))
    }

    // MARK: Characters, words, columns

    /// The characters (grapheme clusters) of a line with their byte columns.
    public func characters(inLine line: Int) -> [(char: Character, start: Int, end: Int)] {
        let s = buffer.lineString(line)
        var out: [(Character, Int, Int)] = []
        var col = 0
        for c in s {
            let n = c.utf8.count
            out.append((c, col, col + n))
            col += n
        }
        return out
    }

    private enum CharKind { case word, space, punctuation }

    private static func kind(of c: Character) -> CharKind {
        if c.isLetter || c.isNumber || c == "_" { return .word }
        if c.isWhitespace { return .space }
        return .punctuation
    }

    public func previousCharacterBoundary(_ offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        let line = buffer.line(containing: offset)
        let start = buffer.lineStarts[line]
        if offset == start { return offset - 1 }  // back over the "\n"
        let col = offset - start
        let chars = characters(inLine: line)
        return start + (chars.last(where: { $0.start < col })?.start ?? 0)
    }

    public func nextCharacterBoundary(_ offset: Int) -> Int {
        guard offset < buffer.byteCount else { return buffer.byteCount }
        let line = buffer.line(containing: offset)
        let range = buffer.lineRange(line)
        if offset >= range.upperBound { return offset + 1 }  // over the "\n"
        let col = offset - range.lowerBound
        let chars = characters(inLine: line)
        return range.lowerBound + (chars.first(where: { $0.end > col })?.end ?? range.count)
    }

    public func previousWordBoundary(_ offset: Int) -> Int {
        let line = buffer.line(containing: offset)
        let start = buffer.lineStarts[line]
        if offset == start { return previousCharacterBoundary(offset) }
        let chars = characters(inLine: line)
        let col = offset - start
        var i = (chars.lastIndex(where: { $0.start < col }) ?? 0)
        while i > 0, Self.kind(of: chars[i].char) == .space { i -= 1 }
        let kind = Self.kind(of: chars[i].char)
        while i > 0, Self.kind(of: chars[i - 1].char) == kind { i -= 1 }
        return start + chars[i].start
    }

    public func nextWordBoundary(_ offset: Int) -> Int {
        let line = buffer.line(containing: offset)
        let range = buffer.lineRange(line)
        if offset >= range.upperBound { return nextCharacterBoundary(offset) }
        let chars = characters(inLine: line)
        let col = offset - range.lowerBound
        var i = chars.firstIndex(where: { $0.end > col }) ?? chars.count
        while i < chars.count, Self.kind(of: chars[i].char) == .space { i += 1 }
        guard i < chars.count else { return range.upperBound }
        let kind = Self.kind(of: chars[i].char)
        while i < chars.count, Self.kind(of: chars[i].char) == kind { i += 1 }
        return range.lowerBound + (i < chars.count ? chars[i].start : range.count)
    }

    /// Visual column (tabs expanded) of a byte offset. The view draws with a monospaced font,
    /// so this is also what lines up vertically.
    public func displayColumn(of offset: Int) -> Int {
        let line = buffer.line(containing: offset)
        let col = offset - buffer.lineStarts[line]
        var visual = 0
        for c in characters(inLine: line) where c.start < col {
            visual = c.char == "\t" ? (visual / settings.tabWidth + 1) * settings.tabWidth : visual + 1
        }
        return visual
    }

    /// Byte offset in `line` closest to visual column `target`.
    public func offset(inLine line: Int, displayColumn target: Int) -> Int {
        let start = buffer.lineStarts[line]
        var visual = 0
        for c in characters(inLine: line) {
            let next = c.char == "\t" ? (visual / settings.tabWidth + 1) * settings.tabWidth : visual + 1
            if next > target { return start + (target - visual <= next - target ? c.start : c.end) }
            visual = next
        }
        return buffer.lineRange(line).upperBound
    }

    private func verticalTarget(from offset: Int, lines delta: Int) -> Int {
        let line = buffer.line(containing: offset)
        let goal = goalColumn ?? displayColumn(of: offset)
        goalColumn = goal
        let target = line + delta
        if target < 0 { return 0 }
        if target >= buffer.lineCount { return buffer.byteCount }
        return self.offset(inLine: target, displayColumn: goal)
    }

    private func leadingWhitespaceEnd(_ line: Int) -> Int {
        let range = buffer.lineRange(line)
        var i = range.lowerBound
        while i < range.upperBound, buffer.byte(at: i) == 0x20 || buffer.byte(at: i) == 0x09 { i += 1 }
        return i
    }

    /// Home goes to the first non-blank character, or to column 0 if already there.
    private func smartLineStart(_ offset: Int) -> Int {
        let line = buffer.line(containing: offset)
        let firstText = leadingWhitespaceEnd(line)
        return offset == firstText ? buffer.lineStarts[line] : firstText
    }

    // MARK: Typing

    private static let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}"]
    private static let closers: Set<Character> = [")", "]", "}"]

    private func character(at offset: Int) -> Character? {
        guard offset < buffer.byteCount else { return nil }
        return buffer.string(in: offset..<nextCharacterBoundary(offset)).first
    }

    private func character(before offset: Int) -> Character? {
        guard offset > 0 else { return nil }
        return buffer.string(in: previousCharacterBoundary(offset)..<offset).first
    }

    public func insertText(_ text: String) {
        if markedRange != nil { replaceMarkedText(with: text); return }
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.insertText(text) }; return }
        let range = selection.range
        if settings.autoCloseBrackets, text.count == 1, let c = text.first {
            if Self.closers.contains(c), range.isEmpty, character(at: range.lowerBound) == c {
                // Type over the closing bracket that is already there.
                move(.right)
                return
            }
            if let close = Self.pairs[c] {
                if !range.isEmpty {
                    let inner = buffer.string(in: range)
                    transact(.other, [(range, "\(c)\(inner)\(close)")],
                             selectAfter: Selection(anchor: range.lowerBound + 1, head: range.upperBound + 1))
                    return
                }
                let next = character(at: range.lowerBound)
                if next == nil || next!.isWhitespace || Self.closers.contains(next!) {
                    let n = text.utf8.count
                    transact(.typing, [(range, "\(c)\(close)")], selectAfter: Selection(caret: range.lowerBound + n))
                    return
                }
            }
        }
        transact(.typing, [(range, text)], selectAfter: Selection(caret: range.lowerBound + text.utf8.count))
    }

    /// Replaces the selection as its own undo step, without auto-closing (used for paste).
    public func replaceSelection(with text: String) {
        commitMarkedText()
        if hasMultipleCursors && batch == nil {
            // One line per cursor (as copied from several cursors) goes one to each; otherwise all get it all.
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            let count = extraSelections.count + 1
            atEachCursor { i in self.replaceSelection(with: lines.count == count ? lines[i] : text) }
            return
        }
        let range = selection.range
        transact(.other, [(range, text)], selectAfter: Selection(caret: range.lowerBound + text.utf8.count))
    }

    public func insertNewline() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.insertNewline() }; return }
        let range = selection.range
        let line = buffer.line(containing: range.lowerBound)
        let lineStart = buffer.lineStarts[line]
        let indent = buffer.string(in: lineStart..<min(leadingWhitespaceEnd(line), range.lowerBound))
        let before = buffer.string(in: lineStart..<range.lowerBound)
            .trimmingCharacters(in: .whitespaces).last
        let after = character(at: range.upperBound)
        let opens = before.map { Self.pairs[$0] != nil || $0 == ":" } ?? false

        if opens, let before, let after, Self.pairs[before] == after {
            // Between a pair: open an indented line and push the closer down.
            let inner = indent + settings.indentUnit
            transact(.other, [(range, "\n" + inner + "\n" + indent)],
                     selectAfter: Selection(caret: range.lowerBound + 1 + inner.utf8.count))
        } else {
            let text = "\n" + indent + (opens ? settings.indentUnit : "")
            transact(.other, [(range, text)], selectAfter: Selection(caret: range.lowerBound + text.utf8.count))
        }
    }

    public func insertTab() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.insertTab() }; return }
        let range = selection.range
        if buffer.line(containing: range.lowerBound) != buffer.line(containing: range.upperBound) {
            indentLines(); return
        }
        if settings.insertSpaces {
            let col = displayColumn(of: range.lowerBound)
            let n = settings.tabWidth - col % settings.tabWidth
            insertText(String(repeating: " ", count: n))
        } else {
            insertText("\t")
        }
    }

    // MARK: Deleting

    public func deleteBackward() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.deleteBackward() }; return }
        let range = selection.range
        if !range.isEmpty { transact(.deleting, [(range, "")], selectAfter: Selection(caret: range.lowerBound)); return }
        guard range.lowerBound > 0 else { return }
        let caret = range.lowerBound
        let line = buffer.line(containing: caret)
        let lineStart = buffer.lineStarts[line]

        // In leading spaces: delete back to the previous tab stop.
        if settings.insertSpaces, caret > lineStart, caret <= leadingWhitespaceEnd(line),
           buffer.string(in: lineStart..<caret).allSatisfy({ $0 == " " }) {
            let col = caret - lineStart
            let stop = (col - 1) / settings.tabWidth * settings.tabWidth
            transact(.deleting, [(lineStart + stop..<caret, "")], selectAfter: Selection(caret: lineStart + stop))
            return
        }
        // Between an empty pair: delete both.
        let prev = previousCharacterBoundary(caret)
        if settings.autoCloseBrackets, let open = character(before: caret), let close = Self.pairs[open],
           character(at: caret) == close {
            transact(.deleting, [(prev..<caret + 1, "")], selectAfter: Selection(caret: prev))
            return
        }
        transact(.deleting, [(prev..<caret, "")], selectAfter: Selection(caret: prev))
    }

    public func deleteForward() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.deleteForward() }; return }
        let range = selection.range
        let target = range.isEmpty ? range.lowerBound..<nextCharacterBoundary(range.lowerBound) : range
        transact(.deleting, [(target, "")], selectAfter: Selection(caret: target.lowerBound))
    }

    public func deleteWordBackward() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.deleteWordBackward() }; return }
        let range = selection.range
        let target = range.isEmpty ? previousWordBoundary(range.lowerBound)..<range.lowerBound : range
        transact(.other, [(target, "")], selectAfter: Selection(caret: target.lowerBound))
    }

    public func deleteWordForward() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.deleteWordForward() }; return }
        let range = selection.range
        let target = range.isEmpty ? range.lowerBound..<nextWordBoundary(range.lowerBound) : range
        transact(.other, [(target, "")], selectAfter: Selection(caret: target.lowerBound))
    }

    public func deleteToLineStart() {
        if hasMultipleCursors && batch == nil { atEachCursor { _ in self.deleteToLineStart() }; return }
        let range = selection.range
        let start = buffer.lineStarts[buffer.line(containing: range.lowerBound)]
        let target = range.isEmpty ? (range.lowerBound == start ? previousCharacterBoundary(start) : start)..<range.lowerBound : range
        transact(.other, [(target, "")], selectAfter: Selection(caret: target.lowerBound))
    }

    // MARK: Clipboard helpers

    /// Text to copy. With nothing selected, copies the whole line (like most code editors).
    public func textToCopy() -> String {
        if hasMultipleCursors {
            let pieces = allSelections.map { s in s.isEmpty ? buffer.lineString(buffer.line(containing: s.head)) : buffer.string(in: s.range) }
            return pieces.joined(separator: "\n") + "\n"
        }
        if !selection.isEmpty { return selectedText }
        let line = buffer.line(containing: selection.head)
        return buffer.lineString(line) + "\n"
    }

    public func cut() -> String {
        let copied = textToCopy()
        if hasMultipleCursors && batch == nil {
            atEachCursor { _ in _ = self.cut() }
            return copied
        }
        if !selection.isEmpty {
            transact(.other, [(selection.range, "")], selectAfter: Selection(caret: selection.range.lowerBound))
        } else {
            let range = lineBlock(buffer.line(containing: selection.head), buffer.line(containing: selection.head))
            transact(.other, [(range, "")], selectAfter: Selection(caret: range.lowerBound))
        }
        return copied
    }

    // MARK: Line operations

    private var selectedLines: ClosedRange<Int> { lines(of: selection) }

    private func lines(of s: Selection) -> ClosedRange<Int> {
        let r = s.range
        let first = buffer.line(containing: r.lowerBound)
        var last = buffer.line(containing: r.upperBound)
        // A selection ending at column 0 doesn't include that line.
        if last > first, r.upperBound == buffer.lineStarts[last] { last -= 1 }
        return first...last
    }

    /// Lines touched by any cursor, each once (so a line with two cursors isn't indented twice).
    private var linesOfAllCursors: [Int] {
        let selections = batch == nil ? allSelections : [selection]
        return Array(Set(selections.flatMap { Array(lines(of: $0)) })).sorted()
    }

    /// Byte range covering whole lines, including the trailing "\n" (or the one before, at the end).
    private func lineBlock(_ first: Int, _ last: Int) -> Range<Int> {
        let start = buffer.lineStarts[first]
        if last + 1 < buffer.lineCount { return start..<buffer.lineStarts[last + 1] }
        return (first > 0 ? start - 1 : start)..<buffer.byteCount
    }

    /// Edits that insert or remove text at line starts; selection is shifted to follow.
    private func editLineStarts(_ edits: [(line: Int, remove: Int, insert: String)]) {
        var replacements: [(Range<Int>, String)] = []
        for e in edits {
            let s = buffer.lineStarts[e.line]
            replacements.append((s..<s + e.remove, e.insert))
        }
        func shift(_ offset: Int) -> Int {
            var result = offset
            for (range, text) in replacements where range.lowerBound < offset {
                let removed = min(range.upperBound, offset) - range.lowerBound
                result += text.utf8.count - removed
            }
            return result
        }
        func shifted(_ s: Selection) -> Selection { Selection(anchor: shift(s.anchor), head: shift(s.head)) }
        transact(.other, replacements, selectAfter: shifted(selection),
                 extrasAfter: batch == nil ? extraSelections.map(shifted) : nil)
    }

    public func indentLines() {
        let unit = settings.indentUnit
        editLineStarts(linesOfAllCursors.compactMap { line in
            buffer.lineRange(line).isEmpty ? nil : (line, 0, unit)
        })
    }

    public func outdentLines() {
        editLineStarts(linesOfAllCursors.compactMap { line in
            let range = buffer.lineRange(line)
            if range.isEmpty { return nil }
            if buffer.byte(at: range.lowerBound) == 0x09 { return (line, 1, "") }
            var n = 0
            while n < settings.tabWidth, range.lowerBound + n < range.upperBound,
                  buffer.byte(at: range.lowerBound + n) == 0x20 { n += 1 }
            return n > 0 ? (line, n, "") : nil
        })
    }

    public func toggleComment() {
        guard let token = settings.lineComment else { return }
        let lines = linesOfAllCursors.filter { !buffer.lineString($0).trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return }
        let allCommented = lines.allSatisfy {
            buffer.lineString($0).trimmingCharacters(in: .whitespaces).hasPrefix(token)
        }
        // Comments go at the shallowest indent so the block stays aligned.
        let indent = lines.map { leadingWhitespaceEnd($0) - buffer.lineStarts[$0] }.min() ?? 0
        var replacements: [(Range<Int>, String)] = []
        for line in lines {
            let start = buffer.lineStarts[line]
            if allCommented {
                let at = leadingWhitespaceEnd(line)
                let tokenLen = token.utf8.count
                let hasSpace = at + tokenLen < buffer.lineRange(line).upperBound && buffer.byte(at: at + tokenLen) == 0x20
                replacements.append((at..<at + tokenLen + (hasSpace ? 1 : 0), ""))
            } else {
                replacements.append((start + indent..<start + indent, token + " "))
            }
        }
        func shift(_ offset: Int) -> Int {
            var result = offset
            for (range, text) in replacements where range.lowerBound < offset {
                result += text.utf8.count - (min(range.upperBound, offset) - range.lowerBound)
            }
            return result
        }
        func shifted(_ s: Selection) -> Selection { Selection(anchor: shift(s.anchor), head: shift(s.head)) }
        transact(.other, replacements, selectAfter: shifted(selection),
                 extrasAfter: batch == nil ? extraSelections.map(shifted) : nil)
    }

    /// Moves the selected lines up (-1) or down (+1).
    public func moveLines(by direction: Int) {
        if hasMultipleCursors { setSelection(selection) }   // moving lines works with one cursor
        let lines = selectedLines
        if direction < 0 && lines.lowerBound == 0 { return }
        if direction > 0 && lines.upperBound == buffer.lineCount - 1 { return }
        let blockText = (lines.lowerBound...lines.upperBound).map { buffer.lineString($0) }.joined(separator: "\n")
        let s = selection
        if direction < 0 {
            let above = lines.lowerBound - 1
            let range = buffer.lineStarts[above]..<buffer.lineRange(lines.upperBound).upperBound
            let aboveText = buffer.lineString(above)
            let shift = -(aboveText.utf8.count + 1)
            transact(.other, [(range, blockText + "\n" + aboveText)],
                     selectAfter: Selection(anchor: s.anchor + shift, head: s.head + shift))
        } else {
            let below = lines.upperBound + 1
            let range = buffer.lineStarts[lines.lowerBound]..<buffer.lineRange(below).upperBound
            let belowText = buffer.lineString(below)
            let shift = belowText.utf8.count + 1
            transact(.other, [(range, belowText + "\n" + blockText)],
                     selectAfter: Selection(anchor: s.anchor + shift, head: s.head + shift))
        }
    }

    // MARK: Find

    /// Finds the next (or previous) match of `needle`, wrapping around the document.
    public func find(_ needle: String, from offset: Int, backwards: Bool = false, caseSensitive: Bool = false) -> Range<Int>? {
        guard !needle.isEmpty else { return nil }
        let haystack = buffer.string
        var options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let utf8 = haystack.utf8
        let pivot = utf8.index(utf8.startIndex, offsetBy: min(offset, utf8.count))
        let first = backwards ? haystack.startIndex..<pivot : pivot..<haystack.endIndex
        let second = haystack.startIndex..<haystack.endIndex  // wrap around
        for scope in [first, second] {
            if let r = haystack.range(of: needle, options: options, range: scope) {
                return utf8.distance(from: utf8.startIndex, to: r.lowerBound)..<utf8.distance(from: utf8.startIndex, to: r.upperBound)
            }
        }
        return nil
    }

    /// Every match in `range` (used to highlight matches on screen).
    public func matches(of needle: String, in range: Range<Int>, caseSensitive: Bool = false) -> [Range<Int>] {
        guard !needle.isEmpty, !range.isEmpty else { return [] }
        let text = buffer.string(in: range)
        var out: [Range<Int>] = []
        var scope = text.startIndex..<text.endIndex
        let utf8 = text.utf8
        while let r = text.range(of: needle, options: caseSensitive ? [] : [.caseInsensitive], range: scope) {
            out.append(range.lowerBound + utf8.distance(from: utf8.startIndex, to: r.lowerBound)
                       ..< range.lowerBound + utf8.distance(from: utf8.startIndex, to: r.upperBound))
            scope = r.upperBound..<text.endIndex
            if r.isEmpty { break }
        }
        return out
    }

    // MARK: Input method (marked) text

    private var markedOriginal: (range: Range<Int>, bytes: [UInt8], selection: Selection)?

    /// Shows in-progress input-method text. `selectedRange` is in UTF-8 bytes within `text`.
    public func setMarkedText(_ text: String, selectedRange: Range<Int>) {
        extraSelections = []   // input methods compose at one place
        let target = markedRange ?? selection.range
        if markedOriginal == nil {
            markedOriginal = (target, buffer.bytes(in: target), selection)
        }
        buffer.replace(target, with: text)
        let n = text.utf8.count
        markedRange = text.isEmpty ? nil : target.lowerBound..<target.lowerBound + n
        selection = Selection(anchor: target.lowerBound + min(selectedRange.lowerBound, n),
                              head: target.lowerBound + min(selectedRange.upperBound, n))
        if markedRange == nil { finishMarked(finalRange: target.lowerBound..<target.lowerBound) }
        onChange?(true)
    }

    private func replaceMarkedText(with text: String) {
        guard let range = markedRange else { return }
        buffer.replace(range, with: text)
        let n = text.utf8.count
        selection = Selection(caret: range.lowerBound + n)
        finishMarked(finalRange: range.lowerBound..<range.lowerBound + n)
        onChange?(true)
    }

    /// Keeps the composed text as typed and ends composition.
    public func commitMarkedText() {
        guard let range = markedRange else { return }
        finishMarked(finalRange: range)
    }

    private func finishMarked(finalRange: Range<Int>) {
        markedRange = nil
        guard let original = markedOriginal else { return }
        markedOriginal = nil
        let newBytes = buffer.bytes(in: finalRange)
        guard newBytes != original.bytes else { return }
        redoStack.removeAll()
        undoStack.append(UndoStep(id: nextStepID, kind: .other,
                                  edits: [EditRecord(start: original.range.lowerBound, oldBytes: original.bytes, newBytes: newBytes)],
                                  selectionBefore: original.selection, selectionAfter: selection))
        nextStepID += 1
        canCoalesce = false
    }
}
