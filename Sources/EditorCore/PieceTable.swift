/// Stores text as UTF-8 bytes in a piece table: the original file bytes are never
/// copied or moved; edits append to an add buffer and rearrange small "pieces".
public struct PieceTable: Sendable {
    enum Source: Sendable { case original, add }

    struct Piece: Sendable {
        var source: Source
        var start: Int
        var length: Int
    }

    private let original: [UInt8]
    private var add: [UInt8] = []
    private(set) var pieces: [Piece]
    public private(set) var count: Int

    public init(_ bytes: [UInt8] = []) {
        original = bytes
        pieces = bytes.isEmpty ? [] : [Piece(source: .original, start: 0, length: bytes.count)]
        count = bytes.count
    }

    /// Finds the piece containing `offset`. At a boundary, returns the piece that starts there.
    /// Returns (pieces.count, 0) for offset == count.
    private func locate(_ offset: Int) -> (index: Int, inner: Int) {
        var pos = 0
        for (i, piece) in pieces.enumerated() {
            if offset < pos + piece.length { return (i, offset - pos) }
            pos += piece.length
        }
        return (pieces.count, 0)
    }

    public mutating func insert<C: Collection>(_ bytes: C, at offset: Int) where C.Element == UInt8 {
        precondition(offset >= 0 && offset <= count, "insert offset out of bounds")
        guard !bytes.isEmpty else { return }
        let addStart = add.count
        add.append(contentsOf: bytes)
        let newPiece = Piece(source: .add, start: addStart, length: bytes.count)
        count += bytes.count

        let (index, inner) = locate(offset)
        // Typing at the end of the last typed piece: just grow it.
        if inner == 0, index > 0 {
            let prev = pieces[index - 1]
            if prev.source == .add, prev.start + prev.length == addStart {
                pieces[index - 1].length += bytes.count
                return
            }
        }
        if inner == 0 {
            pieces.insert(newPiece, at: index)
        } else {
            let piece = pieces[index]
            let left = Piece(source: piece.source, start: piece.start, length: inner)
            let right = Piece(source: piece.source, start: piece.start + inner, length: piece.length - inner)
            pieces.replaceSubrange(index...index, with: [left, newPiece, right])
        }
    }

    public mutating func delete(_ range: Range<Int>) {
        precondition(range.lowerBound >= 0 && range.upperBound <= count, "delete range out of bounds")
        guard !range.isEmpty else { return }
        var result: [Piece] = []
        result.reserveCapacity(pieces.count + 1)
        var pos = 0
        for piece in pieces {
            let pieceRange = pos..<(pos + piece.length)
            pos += piece.length
            if pieceRange.upperBound <= range.lowerBound || pieceRange.lowerBound >= range.upperBound {
                result.append(piece)
                continue
            }
            // Keep the part before the deleted range.
            if pieceRange.lowerBound < range.lowerBound {
                result.append(Piece(source: piece.source, start: piece.start,
                                    length: range.lowerBound - pieceRange.lowerBound))
            }
            // Keep the part after the deleted range.
            if pieceRange.upperBound > range.upperBound {
                let cut = range.upperBound - pieceRange.lowerBound
                result.append(Piece(source: piece.source, start: piece.start + cut,
                                    length: piece.length - cut))
            }
        }
        pieces = result
        count -= range.count
    }

    /// Calls `body` with each contiguous run of bytes in `range`, in order.
    /// Return false from `body` to stop early.
    public func forEachChunk(in range: Range<Int>, _ body: (UnsafeBufferPointer<UInt8>) -> Bool) {
        guard !range.isEmpty else { return }
        var pos = 0
        for piece in pieces {
            let pieceEnd = pos + piece.length
            defer { pos = pieceEnd }
            if pieceEnd <= range.lowerBound { continue }
            if pos >= range.upperBound { break }
            let from = max(range.lowerBound, pos) - pos + piece.start
            let to = min(range.upperBound, pieceEnd) - pos + piece.start
            let keepGoing: Bool = switch piece.source {
            case .original: original.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[from..<to])) }
            case .add: add.withUnsafeBufferPointer { body(UnsafeBufferPointer(rebasing: $0[from..<to])) }
            }
            if !keepGoing { break }
        }
    }

    public func bytes(in range: Range<Int>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(range.count)
        forEachChunk(in: range) { out.append(contentsOf: $0); return true }
        return out
    }

    public func byte(at offset: Int) -> UInt8 {
        let (index, inner) = locate(offset)
        let piece = pieces[index]
        return piece.source == .original ? original[piece.start + inner] : add[piece.start + inner]
    }

    public var allBytes: [UInt8] { bytes(in: 0..<count) }
}
