import Testing
import EditorCore
@testable import Syntax

/// Deeply nested files fill the 1 KB buffer a grammar's scanner saves its state into. A file you
/// open must never write past it, however it's built.
@MainActor
@Suite struct ScannerLimitTests {
    private func parsesAndKeepsParsing(_ language: Language, _ text: String) -> Bool {
        let buffer = TextBuffer(text)
        guard let tree = SyntaxTree(language: language, buffer: buffer) else { return false }
        tree.parseSynchronously()
        buffer.replace(buffer.byteCount..<buffer.byteCount, with: "\n")   // the saved state gets read back
        tree.parseSynchronously()
        return tree.tree != nil
    }

    @Test func deeplyNestedYAML() {
        let text = (0..<320).map { String(repeating: " ", count: $0) + "a:" }.joined(separator: "\n") + "\n"
        #expect(parsesAndKeepsParsing(.yaml, text))
    }

    @Test func deeplyIndentedPythonInsideAString() {
        // One open string makes the saved size odd, so it can step over the end of the buffer.
        let blocks = (0..<530).map { String(repeating: " ", count: $0) + "if 1:" }.joined(separator: "\n")
        let text = blocks + "\n" + String(repeating: " ", count: 530) + "x = \"text\"\n"
        #expect(parsesAndKeepsParsing(.python, text))
    }
}
