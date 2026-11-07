import Foundation
import Testing
@testable import EditorCore

@Suite struct TextSearchTests {
    func find(_ q: String, _ text: String, caseSensitive: Bool = false) -> [TextSearch.Match] {
        TextSearch.matches(of: q, in: Data(text.utf8), caseSensitive: caseSensitive)
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
        let m = TextSearch.matches(of: "x", in: data, caseSensitive: true)
        #expect(m.map(\.line) == [0, 1])
        #expect(m.map(\.column) == [0, 4])
        #expect(m[1].preview == "y = x")
    }

    @Test func binaryFilesAreSkipped() {
        #expect(TextSearch.matches(of: "PNG", in: Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01]), caseSensitive: false).isEmpty)
    }
}

@Suite struct TextSearchLongLineTests {
    @Test func longLinesShowAWindowAroundTheMatch() {
        let text = String(repeating: "x", count: 300) + " needle " + String(repeating: "y", count: 300)
        let m = TextSearch.matches(of: "needle", in: Data(text.utf8), caseSensitive: true)[0]
        #expect(m.preview.hasPrefix("…"))
        let bytes = Array(m.preview.utf8)
        #expect(String(decoding: bytes[m.previewRange], as: UTF8.self) == "needle")
        #expect(m.column == 301)
    }
}
