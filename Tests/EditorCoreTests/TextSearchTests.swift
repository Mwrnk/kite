import Foundation
import Testing
@testable import EditorCore

@Suite struct TextSearchTests {
    func find(_ q: String, _ text: String, caseSensitive: Bool = false) -> [TextSearch.Match] {
        let query = try! FindQuery(q, options: FindOptions(caseSensitive: caseSensitive))
        return TextSearch.matches(of: query, in: TextSearch.text(of: Data(text.utf8))!)
    }

    @Test func linesAndColumns() {
        let m = find("total", "a = 1\n  total = 2\nprint(total)\n")
        #expect(m.map(\.line) == [1, 2])
        #expect(m.map(\.column) == [2, 6])
    }

    @Test func previewTrimsIndentAndMarksMatch() {
        let m = find("total", "    total = 2\n")[0]
        #expect(m.preview == "total = 2")
        #expect(m.previewRange == 0..<5)
    }

    @Test func caseFolding() {
        #expect(find("TOTAL", "total Total TOTAL").count == 3)
        #expect(find("TOTAL", "total Total TOTAL", caseSensitive: true).count == 1)
    }

    @Test func crlfAndBOM() {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("x = 1\r\ny = x\r\n".utf8)
        let m = TextSearch.matches(of: try! FindQuery("x", options: FindOptions(caseSensitive: true)),
                                   in: TextSearch.text(of: data)!)
        #expect(m.map(\.line) == [0, 1])
        #expect(m.map(\.column) == [0, 4])
        #expect(m[1].preview == "y = x")
    }

    @Test func binaryFilesAreSkipped() {
        #expect(TextSearch.text(of: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])) == nil)
    }

    @Test func offsetsMatchTheEditorsText() {
        // CRLF is "\n" in the editor, so offsets after the first line move back by one.
        let text = TextSearch.text(of: Data("ab\r\ncd".utf8))!
        let m = TextSearch.matches(of: try! FindQuery("cd"), in: text)
        #expect(m[0].offset == 3)
        #expect(TextEditor(text).buffer.string(in: 3..<5) == "cd")
    }

    @Test func replacementsComeWithMatches() {
        let query = try! FindQuery("(\\w+)\\(", options: FindOptions(regex: true))
        let m = TextSearch.matches(of: query, in: "  fetchUser(id)\n", template: "load$1(")
        #expect(m[0].replacement == "loadfetchUser(")
        #expect(m[0].preview == "fetchUser(id)")
        #expect(m[0].previewRange == 0..<10)
    }

    @Test func multiLineMatchMarksToLineEnd() {
        let m = TextSearch.matches(of: try! FindQuery("b\nc"), in: "ab\ncd")
        #expect(m[0].line == 0)
        #expect(m[0].preview == "ab")
        #expect(m[0].previewRange == 1..<2)
    }
}

@Suite struct TextSearchLongLineTests {
    @Test func longLinesShowAWindowAroundTheMatch() {
        let text = String(repeating: "x", count: 300) + " needle " + String(repeating: "y", count: 300)
        let m = TextSearch.matches(of: try! FindQuery("needle"), in: text)[0]
        #expect(m.preview.hasPrefix("…"))
        let bytes = Array(m.preview.utf8)
        #expect(String(decoding: bytes[m.previewRange], as: UTF8.self) == "needle")
        #expect(m.column == 301)
    }
}
