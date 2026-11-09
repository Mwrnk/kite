import Testing
@testable import EditorCore

@Suite struct FindQueryTests {
    func q(_ pattern: String, case cs: Bool = false, word: Bool = false, regex: Bool = false) -> FindQuery {
        try! FindQuery(pattern, options: FindOptions(caseSensitive: cs, wholeWord: word, regex: regex))
    }

    /// The matched text, for readable expectations.
    func found(_ query: FindQuery, _ text: String, includeEmpty: Bool = true) -> [String] {
        let bytes = Array(text.utf8)
        return query.matches(in: text, includeEmpty: includeEmpty).map { String(decoding: bytes[$0], as: UTF8.self) }
    }

    func replaceAll(_ query: FindQuery, _ text: String, with template: String, within: Range<Int>? = nil) -> String {
        let e = TextEditor(text)
        e.replace(query.replacements(in: text, within: within, template: template))
        return e.text
    }

    // MARK: Options

    @Test func plainTextIsLiteral() {
        #expect(found(q("a.b"), "a.b axb") == ["a.b"])
        #expect(found(q("(x)"), "f(x) + (x)") == ["(x)", "(x)"])
    }

    @Test func caseInsensitiveByDefault() {
        #expect(found(q("foo"), "Foo FOO foo") == ["Foo", "FOO", "foo"])
        #expect(found(q("foo", case: true), "Foo FOO foo") == ["foo"])
        #expect(found(q("é"), "É é") == ["É", "é"])
    }

    @Test func wholeWord() {
        #expect(found(q("user", word: true), "user users _user user_id fetch(user)") == ["user", "user"])
        #expect(found(q("x+", word: true), "x+ ax+ x+) x+1") == ["x+", "x+"])   // not next to a letter or digit
        #expect(found(q("café", word: true), "café cafés") == ["café"])
    }

    @Test func regexAnchorsWorkPerLine() {
        #expect(found(q("^\\w+", regex: true), "one two\nthree\n  four") == ["one", "three"])
        #expect(found(q("\\d+$", regex: true), "a1\nb22\nc") == ["1", "22"])
    }

    @Test func regexCanSpanLines() {
        #expect(found(q("a\\nb", regex: true), "a\nb") == ["a\nb"])
        #expect(found(q("a\nb"), "a\nb") == ["a\nb"])   // plain text with a newline too
    }

    @Test func invalidRegexIsReported() {
        #expect(throws: FindQuery.Problem.invalid) { try FindQuery("(a", options: FindOptions(regex: true)) }
        #expect(throws: FindQuery.Problem.empty) { try FindQuery("") }
        #expect((try? FindQuery("(a")) != nil)   // fine as plain text
    }

    // MARK: Offsets

    @Test func offsetsAreUTF8Bytes() {
        let text = "😀 é x"   // 😀 is 4 bytes, é 2
        #expect(q("x").matches(in: text) == [8..<9])
        #expect(q("é").matches(in: text) == [5..<7])
        #expect(q("😀").matches(in: text) == [0..<4])
        #expect(q("x").matches(in: text, base: 100) == [108..<109])
    }

    @Test func decomposedAccents() {
        let text = "e\u{301}t"   // "ét" spelled e + combining accent
        #expect(q("t").matches(in: text) == [3..<4])
        #expect(q("e\u{301}").matches(in: text) == [0..<3])
    }

    @Test func withinKeepsContext() {
        let text = "foo bar foo"
        #expect(q("foo").matches(in: text, within: 4..<11) == [8..<11])
        // The lookbehind still sees the letter before the range, so "oo" isn't a whole word there.
        #expect(q("oo", word: true).matches(in: text, within: 1..<3) == [])
        #expect(q("^bar", regex: true).matches(in: text, within: 4..<7) == [])
    }

    @Test func emptyMatches() {
        #expect(q("^", regex: true).matches(in: "a\nb\nc").count == 3)
        #expect(q("^", regex: true).matches(in: "a\nb", includeEmpty: false).isEmpty)
        #expect(found(q("x*", regex: true), "axxb", includeEmpty: false) == ["xx"])
    }

    // MARK: Replacing

    @Test func replacePlainIsLiteral() {
        #expect(replaceAll(q("a"), "a-a", with: "$0\\n") == "$0\\n-$0\\n")
    }

    @Test func replaceRegexGroups() {
        #expect(replaceAll(q("(\\w+)@(\\w+)", regex: true), "me@host", with: "$2 at $1") == "host at me")
        #expect(replaceAll(q("(?<user>\\w+)@", regex: true), "me@x", with: "${user}#") == "me#x")
        #expect(replaceAll(q("(a)", regex: true), "a", with: "${1}1") == "a1")
        #expect(replaceAll(q("(a)", regex: true), "a", with: "$12") == "a2")   // only one group: $1 then "2"
        #expect(replaceAll(q("a", regex: true), "a", with: "\\$1 \\\\ \\t|") == "$1 \\ \t|")
        #expect(replaceAll(q("a", regex: true), "a", with: "x\\ny") == "x\ny")
    }

    @Test func replaceEmptyMatchesPrefixesLines() {
        #expect(replaceAll(q("^", regex: true), "a\nb\n\nc", with: "// ") == "// a\n// b\n// \n// c")
    }

    @Test func replaceWithin() {
        #expect(replaceAll(q("x"), "x x x x", with: "y", within: 2..<5) == "x y y x")
    }

    @Test func replaceAllIsOneUndoStepAndKeepsTheCaret() {
        let e = TextEditor("foo bar foo baz")
        e.setSelection(Selection(caret: 8))   // before the second "foo"
        e.replace(q("foo").replacements(in: e.text, template: "quux"))
        #expect(e.text == "quux bar quux baz")
        #expect(e.selection == Selection(caret: 9))
        e.undo()
        #expect(e.text == "foo bar foo baz")
        #expect(e.selection == Selection(caret: 8))
    }

    @Test func manyReplacementsAreMergedButStayExact() {
        // Over 32 edits become one span edit; the result, the caret and undo must be the same.
        let text = (0..<200).map { "item\($0) = old\($0)\n" }.joined()
        let e = TextEditor(text)
        e.setSelection(Selection(caret: text.utf8.count))   // at the end
        let query = q("old(\\d+)", regex: true)
        e.replace(query.replacements(in: text, template: "new$1!"))
        #expect(e.text == (0..<200).map { "item\($0) = new\($0)!\n" }.joined())
        #expect(e.selection == Selection(caret: e.text.utf8.count))
        e.undo()
        #expect(e.text == text)
        e.redo()
        #expect(e.text.hasPrefix("item0 = new0!\nitem1 = new1!\n"))
    }

    @Test func replacementForCurrentMatch() {
        let query = q("(\\d+)", regex: true)
        #expect(query.replacement(forMatchAt: 2..<4, in: "a 12 b", template: "<$1>") == "<12>")
        #expect(query.replacement(forMatchAt: 2..<3, in: "a 12 b", template: "<$1>") == nil)   // not the whole match
        #expect(q("bar", word: true).replacement(forMatchAt: 3..<6, in: "foobar", template: "x") == nil)
    }

    // MARK: Next and previous

    @Test func nextAndPrevious() {
        let m = [2..<4, 6..<8, 10..<12]
        #expect(FindQuery.next(in: m, after: 0..<0, backwards: false) == 2..<4)
        #expect(FindQuery.next(in: m, after: 2..<4, backwards: false) == 6..<8)
        #expect(FindQuery.next(in: m, after: 10..<12, backwards: false) == 2..<4)   // wraps
        #expect(FindQuery.next(in: m, after: 6..<8, backwards: true) == 2..<4)
        #expect(FindQuery.next(in: m, after: 2..<4, backwards: true) == 10..<12)    // wraps
        #expect(FindQuery.next(in: [], after: 0..<0, backwards: false) == nil)
    }

    @Test func nextStepsPastAnEmptyMatchAtTheCaret() {
        let m = [0..<0, 2..<2, 4..<4]   // "^" in "a\nb\nc"
        #expect(FindQuery.next(in: m, after: 2..<2, backwards: false) == 4..<4)
        #expect(FindQuery.next(in: m, after: 2..<2, backwards: true) == 0..<0)
    }

    @Test func selectAllMatchesAsCursors() {
        let e = TextEditor("a b a b a")
        let matches = q("a").matches(in: e.text)
        e.setSelections(main: Selection(anchor: matches[1].lowerBound, head: matches[1].upperBound),
                        others: matches.map { Selection(anchor: $0.lowerBound, head: $0.upperBound) })
        #expect(e.allSelections.count == 3)
        #expect(e.selection == Selection(anchor: 4, head: 5))
        e.insertText("x")
        #expect(e.text == "x b x b x")
    }
}
