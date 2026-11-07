import Testing
@testable import EditorCore

@Suite struct PieceTableTests {
    @Test func insertAndDelete() {
        var t = PieceTable(Array("hello world".utf8))
        t.insert(Array(", big".utf8), at: 5)
        #expect(String(decoding: t.allBytes, as: UTF8.self) == "hello, big world")
        t.delete(0..<7)
        #expect(String(decoding: t.allBytes, as: UTF8.self) == "big world")
        #expect(t.count == 9)
    }

    @Test func typingCoalescesIntoOnePiece() {
        var t = PieceTable(Array("ab".utf8))
        for (i, c) in "xyz".utf8.enumerated() { t.insert([c], at: 1 + i) }
        #expect(String(decoding: t.allBytes, as: UTF8.self) == "axyzb")
        #expect(t.pieces.count == 3)
    }

    /// Random edits compared against a plain array.
    @Test func matchesArrayUnderRandomEdits() {
        var rng = SplitMix(seed: 42)
        var reference = Array("The quick brown fox\njumps over\nthe lazy dog".utf8)
        var t = PieceTable(reference)
        for _ in 0..<3000 {
            if rng.next() % 3 == 0, !reference.isEmpty {
                let a = Int(rng.next() % UInt64(reference.count))
                let b = min(reference.count, a + Int(rng.next() % 8))
                reference.removeSubrange(a..<b); t.delete(a..<b)
            } else {
                let at = Int(rng.next() % UInt64(reference.count + 1))
                let s = Array(["x", "yz", "\n", "é", "🙂", "abc"][Int(rng.next() % 6)].utf8)
                reference.insert(contentsOf: s, at: at); t.insert(s, at: at)
            }
            #expect(t.count == reference.count)
        }
        #expect(t.allBytes == reference)
        let a = reference.count / 3, b = reference.count / 2
        #expect(t.bytes(in: a..<b) == Array(reference[a..<b]))
    }
}

@Suite struct TextBufferTests {
    @Test func lineIndex() {
        let b = TextBuffer("one\ntwo\n\nfour")
        #expect(b.lineCount == 4)
        #expect(b.lineString(1) == "two")
        #expect(b.lineString(2) == "")
        #expect(b.lineRange(3) == 9..<13)
        #expect(b.line(containing: 4) == 1)
        #expect(b.point(at: 10) == TextPoint(row: 3, column: 1))
    }

    @Test func lineIndexSurvivesRandomEdits() {
        var rng = SplitMix(seed: 7)
        let b = TextBuffer("alpha\nbeta\ngamma\n")
        var reference = b.string
        for _ in 0..<1500 {
            let bytes = Array(reference.utf8)
            let a = Int(rng.next() % UInt64(bytes.count + 1))
            let len = rng.next() % 2 == 0 ? 0 : min(bytes.count - a, Int(rng.next() % 6))
            let text = ["", "\n", "a\nb", "ñ", "zz", "\n\n"][Int(rng.next() % 6)]
            // Keep edits on character boundaries, like the editor does.
            guard (a == bytes.count || bytes[a] & 0xC0 != 0x80),
                  (a + len == bytes.count || bytes[a + len] & 0xC0 != 0x80) else { continue }
            let edit = b.replace(a..<a + len, with: text)
            reference = String(decoding: bytes[..<a] + Array(text.utf8) + bytes[(a + len)...], as: UTF8.self)
            #expect(edit.newEndByte == a + text.utf8.count)
        }
        #expect(b.string == reference)
        let expected = reference.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(b.lineCount == expected.count)
        for (i, line) in expected.enumerated() { #expect(b.lineString(i) == line) }
    }

    @Test func editReportsPoints() {
        let b = TextBuffer("ab\ncd")
        let edit = b.replace(1..<4, with: "X\nY\nZ")
        #expect(edit.startPoint == TextPoint(row: 0, column: 1))
        #expect(edit.oldEndPoint == TextPoint(row: 1, column: 1))
        #expect(edit.newEndPoint == TextPoint(row: 2, column: 1))
        #expect(b.string == "aX\nY\nZd")
    }

    @Test func utf16Bridge() {
        let line = "a🙂é\n"
        let b = TextBuffer(String(repeating: line, count: 3000))
        let lineBytes = line.utf8.count, lineU16 = line.utf16.count
        for row in [0, 1, 1023, 1024, 1025, 2999] {
            let byte = row * lineBytes + 1 + 4  // after "a🙂"
            #expect(b.utf16Offset(ofByte: byte) == row * lineU16 + 3)
            #expect(b.byteOffset(ofUTF16: row * lineU16 + 3) == byte)
        }
        // Inside a surrogate pair rounds forward to a character boundary.
        #expect(b.byteOffset(ofUTF16: 2) == 5)
        b.replace(0..<0, with: "🙂")
        #expect(b.utf16Offset(ofByte: 2000 * lineBytes + 4) == 2000 * lineU16 + 2)
    }
}

@Suite struct TextFileCodecTests {
    @Test func keepsCRLF() throws {
        let (text, format) = TextFileCodec.decode(Data("a\r\nb\r\n".utf8))
        #expect(text == "a\nb\n")
        #expect(format.lineEnding == .crlf)
        #expect(try TextFileCodec.encode(text, format: format) == Data("a\r\nb\r\n".utf8))
    }

    @Test func fallsBackForNonUTF8() {
        let (text, format) = TextFileCodec.decode(Data([0x63, 0x61, 0x66, 0xE9]))  // "café" in Latin-1
        #expect(text == "café")
        #expect(format.encoding == .windowsCP1252)
    }

    @Test func keepsBOM() throws {
        let data = Data([0xEF, 0xBB, 0xBF] + Array("x".utf8))
        let (text, format) = TextFileCodec.decode(data)
        #expect(text == "x" && format.hasBOM)
        #expect(try TextFileCodec.encode(text, format: format) == data)
    }
}

import Foundation

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
