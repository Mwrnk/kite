import Testing
@testable import EditorCore

/// Builds an editor from text where "|" marks the caret, or "[" ... "]" a selection (anchor→head).
func editor(_ marked: String) -> TextEditor {
    var text = marked
    var sel: Selection
    if let open = text.firstIndex(of: "["), let close = text.firstIndex(of: "]") {
        let a = text.utf8.distance(from: text.startIndex, to: open)
        let h = text.utf8.distance(from: text.startIndex, to: close) - 1
        text.remove(at: close); text.remove(at: open)
        sel = Selection(anchor: a, head: h)
    } else {
        let i = text.firstIndex(of: "|")!
        sel = Selection(caret: text.utf8.distance(from: text.startIndex, to: i))
        text.remove(at: i)
    }
    let e = TextEditor(text)
    e.setSelection(sel)
    return e
}

/// The editor's text with "|" inserted at the caret (only for empty selections).
func show(_ e: TextEditor) -> String {
    var bytes = Array(e.text.utf8)
    if e.selection.isEmpty {
        bytes.insert(contentsOf: Array("|".utf8), at: e.caret)
    } else {
        bytes.insert(contentsOf: Array("]".utf8), at: e.selection.range.upperBound)
        bytes.insert(contentsOf: Array("[".utf8), at: e.selection.range.lowerBound)
    }
    return String(decoding: bytes, as: UTF8.self)
}

@Suite struct MovementTests {
    @Test func movesByWholeCharacters() {
        let e = editor("a|👨‍👩‍👧b")
        e.move(.right)
        #expect(show(e) == "a👨‍👩‍👧|b")
        e.move(.left)
        #expect(show(e) == "a|👨‍👩‍👧b")
    }

    @Test func crossesLines() {
        let e = editor("ab|\ncd")
        e.move(.right)
        #expect(show(e) == "ab\n|cd")
        e.move(.left)
        #expect(show(e) == "ab|\ncd")
    }

    @Test func verticalKeepsGoalColumn() {
        let e = editor("hello wo|rld\nhi\nanother line")
        e.move(.down)
        #expect(show(e) == "hello world\nhi|\nanother line")
        e.move(.down)
        #expect(show(e) == "hello world\nhi\nanother |line")
        e.move(.up); e.move(.up)
        #expect(show(e) == "hello wo|rld\nhi\nanother line")
    }

    @Test func verticalCountsTabs() {
        let e = editor("\tx|\n        yz")  // tab = 4 columns, so x is at column 4
        e.move(.down)
        #expect(show(e) == "\tx\n     |   yz")
    }

    @Test func wordJumps() {
        let e = editor("|let foo_bar = baz(1)")
        e.move(.wordRight)
        #expect(show(e) == "let| foo_bar = baz(1)")
        e.move(.wordRight)
        #expect(show(e) == "let foo_bar| = baz(1)")
        e.move(.wordLeft)
        #expect(show(e) == "let |foo_bar = baz(1)")
    }

    @Test func smartHome() {
        let e = editor("    code|")
        e.move(.lineStart)
        #expect(show(e) == "    |code")
        e.move(.lineStart)
        #expect(show(e) == "|    code")
    }

    @Test func shiftExtendsSelection() {
        let e = editor("ab|cd")
        e.move(.right, extend: true); e.move(.right, extend: true)
        #expect(show(e) == "ab[cd]")
        e.move(.left)
        #expect(show(e) == "ab|cd")
    }

    @Test func selectWord() {
        let e = editor("call foo_bar(x)|")
        e.selectWord(at: 7)
        #expect(e.selectedText == "foo_bar")
    }
}

@Suite struct EditingTests {
    @Test func typingReplacesSelection() {
        let e = editor("a[bc]d")
        e.insertText("X")
        #expect(show(e) == "aX|d")
    }

    @Test func autoClosesAndTypesOver() {
        let e = editor("f|")
        e.insertText("(")
        #expect(show(e) == "f(|)")
        e.insertText("x"); e.insertText(")")
        #expect(show(e) == "f(x)|")
    }

    @Test func noAutoCloseBeforeWord() {
        let e = editor("|foo")
        e.insertText("(")
        #expect(show(e) == "(|foo")
    }

    @Test func wrapsSelectionInBrackets() {
        let e = editor("[foo]")
        e.insertText("[")
        #expect(e.text == "[foo]" && e.selectedText == "foo")
    }

    @Test func newlineKeepsIndent() {
        let e = editor("    let x = 1|")
        e.insertNewline()
        #expect(show(e) == "    let x = 1\n    |")
    }

    @Test func newlineBetweenBracesOpensBlock() {
        let e = editor("func f() {|}")
        e.insertNewline()
        #expect(show(e) == "func f() {\n    |\n}")
    }

    @Test func backspaceRemovesIndentLevel() {
        let e = editor("        |x")
        e.deleteBackward()
        #expect(show(e) == "    |x")
    }

    @Test func backspaceRemovesEmptyPair() {
        let e = editor("(|)")
        e.deleteBackward()
        #expect(show(e) == "|")
    }

    @Test func backspaceDeletesWholeEmoji() {
        let e = editor("a🇧🇷|")
        e.deleteBackward()
        #expect(show(e) == "a|")
    }

    @Test func tabInsertsSpacesToNextStop() {
        let e = editor("ab|")
        e.insertTab()
        #expect(show(e) == "ab  |")
    }

    @Test func indentAndOutdentLines() {
        let e = editor("[a\nb]\nc")
        e.indentLines()
        #expect(e.text == "    a\n    b\nc")
        e.outdentLines()
        #expect(e.text == "a\nb\nc")
    }

    @Test func toggleComment() {
        let e = editor("[    a\n      b]")
        e.toggleComment()
        #expect(e.text == "    // a\n    //   b")
        e.toggleComment()
        #expect(e.text == "    a\n      b")
    }

    @Test func moveLines() {
        let e = editor("one\ntw|o\nthree")
        e.moveLines(by: -1)
        #expect(show(e) == "tw|o\none\nthree")
        e.moveLines(by: 1); e.moveLines(by: 1)
        #expect(show(e) == "one\nthree\ntw|o")
    }

    @Test func copyAndCutWholeLineWhenNothingSelected() {
        let e = editor("one\ntw|o\nthree")
        #expect(e.textToCopy() == "two\n")
        _ = e.cut()
        #expect(e.text == "one\nthree")
    }
}

@Suite struct UndoTests {
    @Test func typingUndoesAsWords() {
        let e = editor("|")
        for c in "hello world" { e.insertText(String(c)) }
        e.undo()
        #expect(show(e) == "hello |")
        e.undo()
        #expect(show(e) == "|")
        e.redo(); e.redo()
        #expect(show(e) == "hello world|")
    }

    @Test func undoRestoresMultiLineEdits() {
        let e = editor("[a\nb\nc]")
        e.toggleComment()
        e.undo()
        #expect(e.text == "a\nb\nc")
        #expect(e.selection == Selection(anchor: 0, head: 5))
    }

    @Test func movingCaretBreaksTypingGroup() {
        let e = editor("|")
        e.insertText("a"); e.insertText("b")
        e.move(.left)
        e.insertText("c")
        e.undo()
        #expect(e.text == "ab")
    }

    @Test func dirtyTracking() {
        let e = editor("|")
        #expect(!e.isDirty)
        e.insertText("x")
        #expect(e.isDirty)
        e.markSaved()
        #expect(!e.isDirty)
        e.insertText("y")
        e.undo()
        #expect(!e.isDirty)
        e.undo()
        #expect(e.isDirty)
    }

    @Test func resetTextClearsHistory() {
        let e = editor("abc|")
        e.insertText("d")
        e.resetText("xy")
        #expect(e.text == "xy" && !e.canUndo && !e.isDirty && e.caret == 2)
    }

    @Test func markedTextIsOneUndoStep() {
        let e = editor("a|")
        e.setMarkedText("´", selectedRange: 2..<2)
        #expect(e.markedRange == 1..<3)
        e.insertText("é")
        #expect(show(e) == "aé|")
        #expect(e.markedRange == nil)
        e.undo()
        #expect(show(e) == "a|")
    }
}

@Suite struct FindTests {
    @Test func findWraps() {
        let e = editor("|foo bar Foo")
        #expect(e.find("foo", from: 1) == 8..<11)
        #expect(e.find("foo", from: 1, caseSensitive: true) == 0..<3)
        #expect(e.find("bar", from: 9, backwards: true) == 4..<7)
    }

    @Test func matchesInRange() {
        let e = editor("|ab ab ab")
        #expect(e.matches(of: "ab", in: 2..<8) == [3..<5, 6..<8])
    }
}
