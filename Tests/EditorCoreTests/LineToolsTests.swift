import Testing
@testable import EditorCore

@Suite struct LineToolsTests {
    /// An editor with a cursor at every "|", or a selection between "[" and "]".
    func editor(_ marked: String) -> TextEditor {
        var bytes: [UInt8] = [], carets: [Int] = [], open: Int?
        var selections: [Selection] = []
        for b in marked.utf8 {
            switch b {
            case UInt8(ascii: "|"): carets.append(bytes.count)
            case UInt8(ascii: "["): open = bytes.count
            case UInt8(ascii: "]"): selections.append(Selection(anchor: open!, head: bytes.count))
            default: bytes.append(b)
            }
        }
        let all = selections + carets.map { Selection(caret: $0) }
        let e = TextEditor(String(decoding: bytes, as: UTF8.self))
        e.setSelections(main: all[0], others: Array(all.dropFirst()))
        return e
    }

    func show(_ e: TextEditor) -> String {
        var bytes = Array(e.text.utf8)
        for s in e.allSelections.reversed() {
            if s.isEmpty { bytes.insert(UInt8(ascii: "|"), at: s.head) } else {
                bytes.insert(UInt8(ascii: "]"), at: s.range.upperBound)
                bytes.insert(UInt8(ascii: "["), at: s.range.lowerBound)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func duplicate() {
        let e = editor("a\nb|c\nd")
        e.duplicateLines()
        #expect(show(e) == "a\nbc\nb|c\nd")
        e.undo()
        #expect(e.text == "a\nbc\nd")
    }

    @Test func duplicateBlockAndManyCursors() {
        let e = editor("[a\nb]\nc")
        e.duplicateLines()
        #expect(show(e) == "a\nb\n[a\nb]\nc")
        let m = editor("x|\ny|")
        m.duplicateLines()
        #expect(show(m) == "x\nx|\ny\ny|")
    }

    @Test func delete() {
        let e = editor("a\nb|b\nc")
        e.deleteLines()
        #expect(show(e) == "a\n|c")
        let last = editor("a\nb|")
        last.deleteLines()
        #expect(show(last) == "a|")
        let two = editor("a|\nb|\nc")
        two.deleteLines()
        #expect(show(two) == "|c")
    }

    @Test func join() {
        let e = editor("let x =|\n    1 +\n    2")
        e.joinLines()
        #expect(show(e) == "let x =| 1 +\n    2")
        let block = editor("[a\n  b\n  c]\nd")
        block.joinLines()
        #expect(block.text == "a b c\nd")
        let empty = editor("a|\n\nb")
        empty.joinLines()
        #expect(empty.text == "a\nb")
    }

    @Test func sort() {
        let e = editor("[file10\nfile2\nFile1]\nend")
        #expect(e.sortLines())
        #expect(e.text == "File1\nfile2\nfile10\nend")
        #expect(e.selectedText == "File1\nfile2\nfile10")
        #expect(!editor("one|line").sortLines())
    }

    @Test func caseChanges() {
        let e = editor("hello wor|ld [ok]")
        e.changeCase(.upper)
        #expect(show(e) == "hello [WORLD] [OK]")
        e.changeCase(.title)
        #expect(e.text == "hello World Ok")
        let wide = editor("[straße] x")
        wide.changeCase(.upper)
        #expect(show(wide) == "[STRASSE] x")
    }
}
