import Testing
import EditorCore
@testable import Syntax

/// One small sample per language: each word must end up in the expected color group.
@MainActor
@Suite struct LanguageColorTests {
    private func colors(_ language: Language, _ text: String, _ expected: KeyValuePairs<String, TokenKind>,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        let buffer = TextBuffer(text)
        guard let tree = SyntaxTree(language: language, buffer: buffer) else {
            Issue.record("no tree for \(language)", sourceLocation: sourceLocation)
            return
        }
        tree.parseSynchronously()
        let spans = tree.highlights(in: 0..<buffer.byteCount)
        for (word, kind) in expected {
            guard let found = text.range(of: word) else {
                Issue.record("\(word) isn't in the sample", sourceLocation: sourceLocation)
                continue
            }
            let start = text.utf8.distance(from: text.startIndex, to: found.lowerBound)
            let end = start + word.utf8.count
            let painted = spans.last { $0.range.lowerBound <= start && $0.range.upperBound >= end }?.kind
            #expect(painted == kind, "\(language): \(word)", sourceLocation: sourceLocation)
        }
    }

    @Test func typescript() {
        colors(.typescript, "interface Point { x: number }\nconst a: string = \"hi\"; // note\nfunction go() { return 42 }\n",
               ["interface": .keyword, "Point": .type, "const": .keyword, "\"hi\"": .string,
                "// note": .comment, "go": .function, "42": .number])
    }

    @Test func tsx() {
        colors(.tsx, "interface P {}\nconst A = () => <div className=\"box\">hi</div>; // note\n",
               ["interface": .keyword, "const": .keyword, "div": .tag, "\"box\"": .string, "// note": .comment])
    }

    @Test func markdownBlocksAndInlines() {
        colors(.markdown, "# Title\n\nSome **bold** and `code` with [link](https://x.y).\n\n- item\n\n```swift\nlet x = 1\n```\n",
               ["Title": .keyword, "bold": .constant, "code": .string, "link": .keyword,
                "https://x.y": .comment, "- ": .keyword, "let x = 1": .string])
    }

    @Test func markdownInlineAcrossQuotedLines() {
        colors(.markdown, "> one\n> **two** `three`\n", ["two": .constant, "three": .string, "> ": .comment])
    }

    @Test func markdownInlineFollowsEdits() {
        let buffer = TextBuffer("plain **bold**\n")
        let tree = SyntaxTree(language: .markdown, buffer: buffer)!
        tree.parseSynchronously()
        buffer.replace(0..<0, with: "`code` ")
        tree.parseSynchronously()
        let spans = tree.highlights(in: 0..<buffer.byteCount)
        #expect(spans.contains { $0.kind == .string && $0.range.lowerBound <= 1 && $0.range.upperBound >= 5 })
        let bold = buffer.string.utf8.count - "bold**\n".utf8.count
        #expect(spans.last { $0.range.contains(bold) }?.kind == .constant)
    }

    @Test func hugeMarkdownKeepsBlockColorsOnly() {
        let line = "Some **bold** text.\n\n"
        let text = "# Title\n\n" + String(repeating: line, count: ParseWorker.maxInlineBytes / line.utf8.count + 1)
        let buffer = TextBuffer(text)
        let tree = SyntaxTree(language: .markdown, buffer: buffer)!
        tree.parseSynchronously()
        #expect(tree.tree?.inlinePointer == nil)
        #expect(tree.highlights(in: 0..<20).contains { $0.kind == .keyword })
    }

    @Test func shell() {
        colors(.shell, "# note\nif true; then echo \"hi\"; fi\n",
               ["# note": .comment, "if": .keyword, "echo": .function, "\"hi\"": .string, "fi": .keyword])
    }

    @Test func html() {
        colors(.html, "<!-- note --><div class=\"box\">hi</div>\n",
               ["<!-- note -->": .comment, "div": .tag, "class": .attribute, "box": .string])
    }

    @Test func css() {
        colors(.css, "/* note */ .box { color: red; margin: 42px; }\n@media screen {}\n",
               ["/* note */": .comment, "box": .property, "42": .number, "@media": .keyword])
    }

    @Test func yaml() {
        colors(.yaml, "# note\nname: kite\ncount: 42\nok: true\n",
               ["# note": .comment, "name": .keyword, "kite": .string, "42": .number, "true": .constant])
    }

    @Test func rust() {
        colors(.rust, "// note\nfn main() { let n = 42; println!(\"hi\"); }\nstruct P;\n",
               ["// note": .comment, "fn": .keyword, "main": .function, "let": .keyword, "42": .constant,
                "\"hi\"": .string, "P": .type])
    }

    @Test func go() {
        colors(.go, "// note\npackage main\nfunc run() { n := 42; _ = \"hi\"; _ = n }\ntype P struct{}\n",
               ["// note": .comment, "package": .keyword, "func": .keyword, "run": .function, "42": .number,
                "\"hi\"": .string, "P": .type])
    }

    @Test func c() {
        colors(.c, "// note\nint main(void) { return 42; }\nchar *s = \"hi\";\n",
               ["// note": .comment, "int": .type, "main": .function, "return": .keyword, "42": .number, "\"hi\"": .string])
    }

    @Test func java() {
        colors(.java, "// note\nclass P { int n = 42; String s = \"hi\"; void run() { return; } }\n",
               ["// note": .comment, "class": .keyword, "P": .type, "42": .number, "\"hi\"": .string,
                "run": .function, "return": .keyword])
    }

    @Test func diff() {
        colors(.diff, "diff --git a/x.txt b/x.txt\nindex 123abc..456def 100644\n--- a/x.txt\n+++ b/x.txt\n@@ -1,2 +1,2 @@\n context\n-old line\n+new line\n",
               ["--- a/x.txt": .removed, "+++ b/x.txt": .added, "@@ -1,2 +1,2 @@": .keyword,
                "-old line": .removed, "+new line": .added])
    }

    @Test func fileExtensions() {
        let expected: KeyValuePairs<String, Language> = [
            "ts": .typescript, "mts": .typescript, "cts": .typescript, "tsx": .tsx,
            "md": .markdown, "markdown": .markdown, "mdown": .markdown, "mkd": .markdown,
            "sh": .shell, "bash": .shell, "zsh": .shell, "html": .html, "htm": .html, "css": .css,
            "yaml": .yaml, "yml": .yaml, "rs": .rust, "go": .go, "c": .c, "h": .c,
            "java": .java, "diff": .diff, "patch": .diff,
        ]
        for (ext, language) in expected { #expect(Language.forFileExtension(ext) == language, "\(ext)") }
    }

    @Test func lineComments() {
        for language in [Language.typescript, .tsx, .rust, .go, .c, .java] { #expect(language.lineComment == "//") }
        for language in [Language.shell, .yaml] { #expect(language.lineComment == "#") }
        for language in [Language.markdown, .html, .css, .diff] { #expect(language.lineComment == nil) }
    }
}
