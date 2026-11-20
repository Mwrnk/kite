import Testing
@testable import Markdown

@Suite struct MarkdownDocumentTests {
    /// Each block's spans joined into one string.
    private func texts(_ doc: MarkdownDocument) -> [String] {
        doc.blocks.map { $0.spans.map(\.text).joined() }
    }

    private func cellTexts(_ cells: [[MarkdownSpan]]) -> [String] {
        cells.map { $0.map(\.text).joined() }
    }

    @Test func headingsAndParagraphs() {
        let doc = MarkdownDocument.parse("# Title\n\nOne\ntwo")
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].kind == .heading(level: 1))
        #expect(doc.blocks[0].spans == [MarkdownSpan(text: "Title")])
        #expect(doc.blocks[0].lines == 0...0)
        #expect(doc.blocks[1].kind == .paragraph)
        #expect(texts(doc)[1] == "One two")
        #expect(doc.blocks[1].lines == 2...3)
    }

    @Test func inlineStyles() {
        let doc = MarkdownDocument.parse("a *b* **c** `d` ~~e~~ [f](https://x.y)")
        #expect(doc.blocks.count == 1)
        let spans = doc.blocks[0].spans
        func span(_ text: String) -> MarkdownSpan? { spans.first { $0.text == text } }
        #expect(span("b")?.style == .emphasis)
        #expect(span("c")?.style == .strong)
        #expect(span("d")?.style == .code)
        #expect(span("e")?.style == .strikethrough)
        #expect(span("f")?.link == "https://x.y")
    }

    @Test func hardBreakIsNewline() {
        #expect(texts(MarkdownDocument.parse("a  \nb")) == ["a\nb"])
    }

    @Test func nestedLists() {
        let doc = MarkdownDocument.parse("- a\n  - b\n\n1. c\n2. d")
        #expect(doc.blocks.map(\.marker) == [.bullet, .bullet, .number(1), .number(2)])
        #expect(doc.blocks.map(\.listDepth) == [1, 2, 1, 1])
        #expect(texts(doc) == ["a", "b", "c", "d"])
    }

    @Test func taskItems() {
        let doc = MarkdownDocument.parse("- [ ] todo\n- [x] done")
        #expect(doc.blocks.map(\.marker) == [.task(done: false), .task(done: true)])
        #expect(texts(doc) == ["todo", "done"])
    }

    @Test func secondParagraphInItemHasNoMarker() {
        let doc = MarkdownDocument.parse("- a\n\n  more")
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks.map(\.marker) == [.bullet, nil])
        #expect(doc.blocks.map(\.listDepth) == [1, 1])
    }

    @Test func quotes() {
        let doc = MarkdownDocument.parse("> a\n>\n>> b")
        #expect(doc.blocks.map(\.quoteDepth) == [1, 2])
        #expect(texts(doc) == ["a", "b"])
    }

    @Test func codeBlock() {
        let doc = MarkdownDocument.parse("```swift\nlet x = 1\n```")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].kind == .codeBlock(language: "swift"))
        #expect(doc.blocks[0].spans == [MarkdownSpan(text: "let x = 1", style: .code)])
        #expect(doc.blocks[0].lines == 0...2)
    }

    @Test func unclosedFence() {
        let doc = MarkdownDocument.parse("# A\n```\ncode")
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[1].kind == .codeBlock(language: nil))
        #expect(texts(doc)[1] == "code")
    }

    @Test func table() {
        let doc = MarkdownDocument.parse("| a | b |\n|---|:-:|\n| 1 | 2 |")
        #expect(doc.blocks.count == 1)
        guard case .table(let table) = doc.blocks[0].kind else {
            Issue.record("not a table: \(doc.blocks[0].kind)")
            return
        }
        #expect(table.columns == [.left, .center])
        #expect(cellTexts(table.header) == ["a", "b"])
        #expect(table.rows.map(cellTexts) == [["1", "2"]])
        #expect(doc.blocks[0].lines == 0...2)
    }

    @Test func ruleAndImage() {
        let doc = MarkdownDocument.parse("---\n\n![alt](pic.png)")
        #expect(doc.blocks.count == 2)
        #expect(doc.blocks[0].kind == .rule)
        #expect(doc.blocks[1].kind == .paragraph)
        #expect(doc.blocks[1].spans == [MarkdownSpan(text: "alt", image: "pic.png")])
    }

    @Test func rawHTML() {
        let spans = MarkdownDocument.parse("<b>x</b> y").blocks.first?.spans ?? []
        #expect(spans.first { $0.text == "<b>" }?.style == .html)
        #expect(spans.first { $0.text == "</b>" }?.style == .html)
    }

    @Test func htmlBlockIsKeptAsDimText() {
        let doc = MarkdownDocument.parse("<p align=\"center\"><img src=\"a.png\"></p>\n\n# A\n\n<div>\nx\n</div>")
        #expect(doc.blocks.count == 3)
        #expect(doc.blocks[0].kind == .paragraph)
        #expect(doc.blocks[0].spans == [MarkdownSpan(text: "<p align=\"center\"><img src=\"a.png\"></p>", style: .html)])
        #expect(doc.blocks[0].lines == 0...0)
        #expect(doc.blocks[1].kind == .heading(level: 1))
        #expect(doc.blocks[2].spans == [MarkdownSpan(text: "<div>\nx\n</div>", style: .html)])
        #expect(doc.blocks[2].lines == 4...6)
    }

    @Test func linesAfterEmoji() {
        let doc = MarkdownDocument.parse("# 👨‍👩‍👧 é\n\npara")
        #expect(doc.blocks.map(\.lines) == [0...0, 2...2])
    }

    @Test func empty() {
        #expect(MarkdownDocument.parse("").blocks.isEmpty)
        #expect(MarkdownDocument.parse("  \n\n").blocks.isEmpty)
    }

    @Test func blockIndexForLine() {
        let doc = MarkdownDocument.parse("# A\n\nb\nc\n\n- d")
        #expect(doc.blockIndex(forLine: 0) == 0)
        #expect(doc.blockIndex(forLine: 1) == 0)
        #expect(doc.blockIndex(forLine: 2) == 1)
        #expect(doc.blockIndex(forLine: 3) == 1)
        #expect(doc.blockIndex(forLine: 5) == 2)
        #expect(MarkdownDocument.parse("").blockIndex(forLine: 0) == nil)
    }
}
