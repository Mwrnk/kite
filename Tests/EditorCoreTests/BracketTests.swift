import Testing
@testable import EditorCore

@Suite struct BracketTests {
    /// Caret at the "|" in `text` (which must not contain other "|").
    func pair(_ marked: String, ignore: (Int) -> Bool = { _ in false }) -> (Int, Int)? {
        let caret = marked.utf8.firstIndex(of: UInt8(ascii: "|")).map { marked.utf8.distance(from: marked.utf8.startIndex, to: $0) }!
        var text = marked
        text.remove(at: text.firstIndex(of: "|")!)
        let e = TextEditor(text)
        e.setSelection(Selection(caret: caret))
        return e.bracketPair(near: caret, ignore: ignore)
    }

    @Test func caretBeforeOpening() {
        let p = pair("f|(a(b)c)")
        #expect(p?.0 == 1 && p?.1 == 7)
    }

    @Test func caretAfterClosing() {
        let p = pair("f(a(b)c)|")
        #expect(p?.0 == 1 && p?.1 == 7)
    }

    @Test func afterCaretWinsOverBefore() {
        // "(|[" : the "[" after the caret is preferred over the "(" before it.
        let p = pair("(|[x])")
        #expect(p?.0 == 1 && p?.1 == 3)
    }

    @Test func kindsDontMix() {
        let p = pair("|{ ( ] }")
        #expect(p?.0 == 0 && p?.1 == 6)
    }

    @Test func acrossLines() {
        let p = pair("if x |{\n    y()\n}")
        #expect(p?.0 == 5 && p?.1 == 15)
    }

    @Test func unmatchedGivesNil() {
        #expect(pair("|(abc") == nil)
        #expect(pair("ab|c") == nil)
    }

    @Test func ignoredBracketsDontCount() {
        // print("(") ; the "(" inside the string (offset 7) must be skipped.
        let text = "print(\"(\")|"
        let p = pair(text, ignore: { $0 == 7 })
        #expect(p?.0 == 5 && p?.1 == 9)
    }
}
