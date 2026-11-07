import Testing
@testable import EditorCore

@Suite struct FuzzyMatchTests {
    let files = [
        "Sources/Kite/EditorView.swift",
        "Sources/Kite/EditorWindowController.swift",
        "Sources/Kite/main.swift",
        "Sources/Kite/MainMenu.swift",
        "Sources/EditorCore/TextEditor.swift",
        "docs/TUTOR-SPEC.md",
        "Tests/EditorCoreTests/EditorTests.swift",
    ].map(FuzzyCandidate.init)

    func top(_ query: String) -> String? {
        FuzzyMatch.rank(query, files).first.map { files[$0.index].text }
    }

    @Test func lettersMustAppearInOrder() {
        #expect(FuzzyMatch.match("edv", files[0]) != nil)
        #expect(FuzzyMatch.match("vde", files[0]) == nil)
    }

    @Test func wordStartsWin() {
        #expect(top("ev") == "Sources/Kite/EditorView.swift")
        #expect(top("ewc") == "Sources/Kite/EditorWindowController.swift")
    }

    @Test func exactNameBeatsLongerName() {
        #expect(top("main") == "Sources/Kite/main.swift")
        #expect(top("mainm") == "Sources/Kite/MainMenu.swift")
    }

    @Test func caseIgnoredAndFoldersCount() {
        #expect(top("TUTOR") == "docs/TUTOR-SPEC.md")
        #expect(top("core text") == "Sources/EditorCore/TextEditor.swift")
    }

    @Test func positionsPointAtMatchedLetters() {
        let r = FuzzyMatch.match("ev", files[0])!
        let text = Array(files[0].text.utf8)
        #expect(r.positions.map { Character(UnicodeScalar(text[$0])) } == ["E", "V"])
    }
}
