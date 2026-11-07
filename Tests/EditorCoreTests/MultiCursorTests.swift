import Testing
@testable import EditorCore

@Suite struct MultiCursorTests {
    /// An editor with a cursor at every "|" in `marked`.
    func cursors(_ marked: String) -> TextEditor {
        var offsets: [Int] = []
        var bytes: [UInt8] = []
        for b in marked.utf8 { if b == UInt8(ascii: "|") { offsets.append(bytes.count) } else { bytes.append(b) } }
        let e = TextEditor(String(decoding: bytes, as: UTF8.self))
        e.setSelection(Selection(caret: offsets[0]))
        for o in offsets.dropFirst() { e.addSelection(Selection(caret: o)) }
        return e
    }

    /// Text with "|" at every cursor (empty selections only).
    func show(_ e: TextEditor) -> String {
        var bytes = Array(e.text.utf8)
        for s in e.allSelections.reversed() { bytes.insert(UInt8(ascii: "|"), at: s.head) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func typingGoesToEveryCursor() {
        let e = cursors("a|\nb|\nc|")
        e.insertText("!")
        #expect(show(e) == "a!|\nb!|\nc!|")
    }

    @Test func oneUndoStepForAllCursors() {
        let e = cursors("a|\nb|\nc|")
        e.insertText("1")
        e.insertText("2")
        e.undo()
        #expect(show(e) == "a1|\nb1|\nc1|")
        e.undo()
        #expect(show(e) == "a|\nb|\nc|")
        e.redo()
        #expect(show(e) == "a1|\nb1|\nc1|")
    }

    @Test func deleteBackwardAtEachCursor() {
        let e = cursors("ab|\ncd|\nef|")
        e.deleteBackward()
        #expect(show(e) == "a|\nc|\ne|")
    }

    @Test func newlineKeepsIndentAtEachCursor() {
        let e = cursors("    x|\n    y|")
        e.insertNewline()
        #expect(show(e) == "    x\n    |\n    y\n    |")
    }

    @Test func movingMergesCursorsThatMeet() {
        let e = cursors("|a|b")
        e.move(.left)
        #expect(e.allSelections.count == 1)
        #expect(show(e) == "|ab")
    }

    @Test func addNextOccurrenceThenType() {
        let e = TextEditor("foo bar foo baz foo")
        e.setSelection(Selection(caret: 1))
        e.addNextOccurrence()          // selects the word
        e.addNextOccurrence()
        e.addNextOccurrence()
        #expect(e.allSelections.count == 3)
        e.addNextOccurrence()          // nothing left to add
        #expect(e.allSelections.count == 3)
        e.insertText("x")
        #expect(e.text == "x bar x baz x")
    }

    @Test func splitIntoLinesThenAppend() {
        let e = TextEditor("one\ntwo\nthree")
        e.setSelection(Selection(anchor: 0, head: e.buffer.byteCount))
        e.splitSelectionIntoLines()
        #expect(e.allSelections.count == 3)
        e.move(.lineEnd)
        e.insertText(";")
        #expect(e.text == "one;\ntwo;\nthree;")
    }

    @Test func copyFromCursorsPastesOneLineEach() {
        let e = TextEditor("a1 b2 c3")
        e.setSelection(Selection(anchor: 0, head: 1))
        e.addSelection(Selection(anchor: 3, head: 4))
        e.addSelection(Selection(anchor: 6, head: 7))
        let copied = e.textToCopy()
        #expect(copied == "a\nb\nc\n")
        e.move(.lineEnd)               // all three land at the end and merge
        #expect(e.allSelections.count == 1)
        let e2 = cursors("x|\ny|\nz|")
        e2.replaceSelection(with: copied)
        #expect(show(e2) == "xa|\nyb|\nzc|")
    }

    @Test func indentOnceForTwoCursorsOnOneLine() {
        let e = cursors("a|b|c\nd")
        e.indentLines()
        #expect(e.text == "    abc\nd")
        #expect(show(e) == "    a|b|c\nd")
    }

    @Test func toggleCommentAcrossCursors() {
        let e = cursors("|a\nb\n|c")
        e.settings.lineComment = "#"
        e.toggleComment()
        #expect(e.text == "# a\nb\n# c")
    }

    @Test func clickingCollapsesAndEscapeToo() {
        let e = cursors("|a|b|c")
        e.collapseToMainCursor()
        #expect(e.allSelections.count == 1)
        let e2 = cursors("|a|b")
        e2.setSelection(Selection(caret: 0))
        #expect(!e2.hasMultipleCursors)
    }

    @Test func optionClickOnACursorRemovesIt() {
        let e = cursors("|a|b|c")
        e.addSelection(Selection(caret: 1))
        #expect(e.allSelections.map(\.head) == [0, 2])
    }

    @Test func addCursorBelowKeepsColumn() {
        let e = cursors("ab|c\nxyz\n12")
        e.addCursorVertically(1)
        e.addCursorVertically(1)
        #expect(show(e) == "ab|c\nxy|z\n12|")
    }
}
