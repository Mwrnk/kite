extension TextEditor {
    /// The bracket touching `offset` and its partner, as byte offsets, or nil if there's no bracket
    /// there or no partner within `limit` bytes. The character right after the caret wins over the one
    /// right before it. `ignore` says whether a bracket at a byte offset is inside a string or comment,
    /// so `"("` in a string doesn't pair with real code.
    public func bracketPair(near offset: Int, limit: Int = 100_000,
                            ignore: (Int) -> Bool = { _ in false }) -> (Int, Int)? {
        let buffer = self.buffer
        var candidates: [Int] = []
        if offset < buffer.byteCount { candidates.append(offset) }
        if offset > 0 { candidates.append(offset - 1) }

        for at in candidates {
            guard let bracket = Bracket(buffer.byte(at: at)), !ignore(at) else { continue }
            if bracket.isOpen {
                let end = min(buffer.byteCount, at + 1 + limit)
                let bytes = buffer.bytes(in: (at + 1)..<end)
                var depth = 0
                for (i, b) in bytes.enumerated() {
                    guard let other = Bracket(b), other.pair == bracket.pair, !ignore(at + 1 + i) else { continue }
                    if other.isOpen { depth += 1 } else if depth == 0 { return (at, at + 1 + i) } else { depth -= 1 }
                }
            } else {
                let start = max(0, at - limit)
                let bytes = buffer.bytes(in: start..<at)
                var depth = 0
                for i in stride(from: bytes.count - 1, through: 0, by: -1) {
                    guard let other = Bracket(bytes[i]), other.pair == bracket.pair, !ignore(start + i) else { continue }
                    if !other.isOpen { depth += 1 } else if depth == 0 { return (start + i, at) } else { depth -= 1 }
                }
            }
        }
        return nil
    }
}

private struct Bracket {
    let pair: UInt8      // the opening byte, identifies the kind
    let isOpen: Bool

    init?(_ byte: UInt8) {
        switch byte {
        case UInt8(ascii: "("): (pair, isOpen) = (byte, true)
        case UInt8(ascii: ")"): (pair, isOpen) = (UInt8(ascii: "("), false)
        case UInt8(ascii: "["): (pair, isOpen) = (byte, true)
        case UInt8(ascii: "]"): (pair, isOpen) = (UInt8(ascii: "["), false)
        case UInt8(ascii: "{"): (pair, isOpen) = (byte, true)
        case UInt8(ascii: "}"): (pair, isOpen) = (UInt8(ascii: "{"), false)
        default: return nil
        }
    }
}
