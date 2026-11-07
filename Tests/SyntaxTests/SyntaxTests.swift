import Testing
import EditorCore
@testable import Syntax

@MainActor
@Suite struct SyntaxTests {
    /// The kind painted last over the first occurrence of `word`.
    func kind(of word: String, in tree: SyntaxTree, buffer: TextBuffer) -> TokenKind? {
        tree.parseSynchronously()
        let text = buffer.string
        let start = text.utf8.distance(from: text.startIndex, to: text.range(of: word)!.lowerBound)
        let r = start..<start + word.utf8.count
        return tree.highlights(in: 0..<buffer.byteCount).last { $0.range.contains(r.lowerBound) && $0.range.upperBound >= r.upperBound }?.kind
    }

    @Test(arguments: Language.allCases)
    func everyQueryCompiles(language: Language) {
        #expect(SyntaxTree(language: language, buffer: TextBuffer("x")) != nil)
    }

    @Test func swiftColors() {
        let b = TextBuffer("""
        // hello
        struct Point { let x: Int = 42 }
        func greet(name: String) -> String { return "hi \\(name)" }
        """)
        let tree = SyntaxTree(language: .swift, buffer: b)!
        #expect(kind(of: "// hello", in: tree, buffer: b) == .comment)
        #expect(kind(of: "struct", in: tree, buffer: b) == .keyword)
        #expect(kind(of: "Point", in: tree, buffer: b) == .type)
        #expect(kind(of: "42", in: tree, buffer: b) == .number)
        #expect(kind(of: "greet", in: tree, buffer: b) == .function)
        #expect(kind(of: "hi ", in: tree, buffer: b) == .string)
    }

    @Test func pythonPredicates() {
        let b = TextBuffer("class Foo:\n    MAX = 3\n    def run(self): print(self)\n")
        let tree = SyntaxTree(language: .python, buffer: b)!
        #expect(kind(of: "MAX", in: tree, buffer: b) == .constant)    // #match? "^[A-Z][A-Z_0-9]*$"
        #expect(kind(of: "print", in: tree, buffer: b) == .builtin)   // #any-of? / #match? builtin list
        #expect(kind(of: "def", in: tree, buffer: b) == .keyword)
    }

    @Test func incrementalEditsKeepTreeInSync() {
        let b = TextBuffer("let a = 1\n")
        let tree = SyntaxTree(language: .javascript, buffer: b)!
        tree.parseSynchronously()
        b.replace(8..<9, with: "\"one\"")
        #expect(kind(of: "\"one\"", in: tree, buffer: b) == .string)
        b.replace(0..<0, with: "// note\n")
        #expect(kind(of: "// note", in: tree, buffer: b) == .comment)
        #expect(!tree.debugDescription.contains("ERROR"))
    }

    @Test func languageFromExtension() {
        #expect(Language.forFileExtension("SWIFT") == .swift)
        #expect(Language.forFileExtension("mjs") == .javascript)
        #expect(Language.forFileExtension("txt") == nil)
    }
}
