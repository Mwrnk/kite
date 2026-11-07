/// A row and a byte column, the same coordinates tree-sitter uses.
public struct TextPoint: Equatable, Hashable, Sendable {
    public var row: Int
    public var column: Int
    public init(row: Int, column: Int) { self.row = row; self.column = column }
}

/// Describes one change to the buffer, in byte offsets and points.
/// Syntax parsing (and later the tutor) listens to these.
public struct BufferEdit: Equatable, Sendable {
    public let startByte: Int
    public let oldEndByte: Int
    public let newEndByte: Int
    public let startPoint: TextPoint
    public let oldEndPoint: TextPoint
    public let newEndPoint: TextPoint
}

/// The document text: a piece table plus an index of where each line starts.
/// Offsets are UTF-8 byte offsets. Lines end with "\n" (files are normalized on load).
public final class TextBuffer {
    public private(set) var storage: PieceTable
    /// Byte offset where each line starts. Always non-empty; first entry is 0.
    public private(set) var lineStarts: [Int]
    /// Bumps on every change, so caches can tell when they are stale.
    public private(set) var version = 0
    /// Longest line seen, in bytes. Only grows while editing; used for horizontal scroll width.
    public private(set) var maxLineLength = 0

    private var observers: [(BufferEdit) -> Void] = []

    // UTF-16 offset of the start of every `checkpointStride`th line, computed lazily.
    private static let checkpointStride = 1024
    private var utf16Checkpoints: [Int] = [0]

    public init(_ string: String = "") {
        let bytes = Array(string.utf8)
        storage = PieceTable(bytes)
        lineStarts = [0]
        for (i, b) in bytes.enumerated() where b == 0x0A { lineStarts.append(i + 1) }
        for line in 0..<lineStarts.count { maxLineLength = max(maxLineLength, lineRange(line).count) }
    }

    public var byteCount: Int { storage.count }
    public var lineCount: Int { lineStarts.count }
    public var string: String { String(decoding: storage.allBytes, as: UTF8.self) }

    public func addObserver(_ observer: @escaping (BufferEdit) -> Void) {
        observers.append(observer)
    }

    // MARK: Lines and points

    /// Byte range of a line, not including its "\n".
    public func lineRange(_ line: Int) -> Range<Int> {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : storage.count
        return start..<end
    }

    /// Index of the line containing `offset`.
    public func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    public func point(at offset: Int) -> TextPoint {
        let row = line(containing: offset)
        return TextPoint(row: row, column: offset - lineStarts[row])
    }

    public func offset(of point: TextPoint) -> Int {
        let row = min(max(point.row, 0), lineCount - 1)
        let range = lineRange(row)
        return range.lowerBound + min(max(point.column, 0), range.count)
    }

    public func lineString(_ line: Int) -> String { string(in: lineRange(line)) }

    public func string(in range: Range<Int>) -> String {
        String(decoding: storage.bytes(in: range), as: UTF8.self)
    }

    public func bytes(in range: Range<Int>) -> [UInt8] { storage.bytes(in: range) }

    public func byte(at offset: Int) -> UInt8 { storage.byte(at: offset) }

    // MARK: Editing

    /// Replaces `range` with `text` and returns the edit. `range` must fall on
    /// character boundaries; the editor guarantees this.
    @discardableResult
    public func replace(_ range: Range<Int>, with text: String) -> BufferEdit {
        replace(range, withBytes: Array(text.utf8))
    }

    @discardableResult
    public func replace(_ range: Range<Int>, withBytes newBytes: [UInt8]) -> BufferEdit {
        precondition(range.lowerBound >= 0 && range.upperBound <= byteCount)
        let startPoint = point(at: range.lowerBound)
        let oldEndPoint = point(at: range.upperBound)

        storage.delete(range)
        storage.insert(newBytes, at: range.lowerBound)

        // Update the line index: drop lines inside the old range, shift the rest,
        // then add the line starts the new text introduces.
        let firstLine = startPoint.row
        let delta = newBytes.count - range.count
        var newStarts: [Int] = []
        for (i, b) in newBytes.enumerated() where b == 0x0A { newStarts.append(range.lowerBound + i + 1) }
        if delta != 0 {
            lineStarts.withUnsafeMutableBufferPointer { starts in
                for i in (oldEndPoint.row + 1)..<starts.count { starts[i] += delta }
            }
        }
        lineStarts.replaceSubrange((firstLine + 1)..<(oldEndPoint.row + 1), with: newStarts)

        let newEndByte = range.lowerBound + newBytes.count
        let newEndPoint = point(at: newEndByte)
        for line in firstLine...newEndPoint.row {
            maxLineLength = max(maxLineLength, lineRange(line).count)
        }
        let keep = firstLine / Self.checkpointStride + 1
        if utf16Checkpoints.count > keep { utf16Checkpoints.removeLast(utf16Checkpoints.count - keep) }
        version += 1

        let edit = BufferEdit(startByte: range.lowerBound, oldEndByte: range.upperBound,
                              newEndByte: newEndByte, startPoint: startPoint,
                              oldEndPoint: oldEndPoint, newEndPoint: newEndPoint)
        for observer in observers { observer(edit) }
        return edit
    }

    // MARK: UTF-16 bridge (AppKit's text input speaks UTF-16)

    private static func utf16Length(of bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var n = 0
        for b in bytes where b & 0xC0 != 0x80 { n += b >= 0xF0 ? 2 : 1 }
        return n
    }

    private func utf16Length(_ range: Range<Int>) -> Int {
        var n = 0
        storage.forEachChunk(in: range) { n += Self.utf16Length(of: $0); return true }
        return n
    }

    private func checkpointLine(_ k: Int) -> Int { k * Self.checkpointStride }

    /// Makes sure checkpoint `k` exists (if that line exists).
    private func ensureCheckpoint(_ k: Int) {
        while utf16Checkpoints.count <= k {
            let prev = utf16Checkpoints.count - 1
            let nextLine = checkpointLine(prev + 1)
            guard nextLine < lineCount else { return }
            let from = lineStarts[checkpointLine(prev)]
            utf16Checkpoints.append(utf16Checkpoints[prev] + utf16Length(from..<lineStarts[nextLine]))
        }
    }

    public func utf16Offset(ofByte offset: Int) -> Int {
        let k = line(containing: offset) / Self.checkpointStride
        ensureCheckpoint(k)
        return utf16Checkpoints[k] + utf16Length(lineStarts[checkpointLine(k)]..<offset)
    }

    /// The byte offset for a UTF-16 offset, clamped to the buffer.
    public func byteOffset(ofUTF16 target: Int) -> Int {
        if target <= 0 { return 0 }
        // Find the last checkpoint at or before the target.
        var k = 0
        while true {
            ensureCheckpoint(k + 1)
            if k + 1 < utf16Checkpoints.count, utf16Checkpoints[k + 1] <= target { k += 1 } else { break }
        }
        var u = utf16Checkpoints[k]
        var result = lineStarts[checkpointLine(k)]
        storage.forEachChunk(in: result..<byteCount) { chunk in
            for b in chunk {
                if b & 0xC0 != 0x80 {
                    if u >= target { return false }
                    u += b >= 0xF0 ? 2 : 1
                }
                result += 1
            }
            return true
        }
        // Step past continuation bytes so we never land inside a character.
        while result < byteCount, byte(at: result) & 0xC0 == 0x80 { result += 1 }
        return result
    }
}
