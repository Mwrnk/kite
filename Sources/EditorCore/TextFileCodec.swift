import Foundation

public enum LineEnding: String, Sendable {
    case lf = "\n", crlf = "\r\n", cr = "\r"

    public var label: String {
        switch self { case .lf: "LF"; case .crlf: "CRLF"; case .cr: "CR" }
    }
}

/// How a file was stored on disk, so saving writes it back the same way.
public struct FileFormat: Equatable, Sendable {
    public var encoding: String.Encoding
    public var lineEnding: LineEnding
    public var hasBOM: Bool

    public init(encoding: String.Encoding = .utf8, lineEnding: LineEnding = .lf, hasBOM: Bool = false) {
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasBOM = hasBOM
    }

    public var encodingLabel: String {
        switch encoding {
        case .utf8: hasBOM ? "UTF-8 with BOM" : "UTF-8"
        case .utf16, .utf16LittleEndian, .utf16BigEndian: "UTF-16"
        case .isoLatin1: "ISO Latin 1"
        case .windowsCP1252: "Windows 1252"
        case .macOSRoman: "Mac Roman"
        default: String.localizedName(of: encoding)
        }
    }
}

public enum TextFileCodec {
    /// Decodes file bytes into text with "\n" line endings, and remembers the original format.
    public static func decode(_ data: Data) -> (text: String, format: FileFormat) {
        var format = FileFormat()
        var text: String

        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) {
            text = s
            format.hasBOM = true
        } else if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
                  let s = String(data: data, encoding: .utf16) {
            text = s
            format.encoding = .utf16
        } else if let s = String(data: data, encoding: .utf8) {
            text = s
        } else if let s = String(data: data, encoding: .windowsCP1252) {
            text = s
            format.encoding = .windowsCP1252
        } else {
            text = String(decoding: data, as: UTF8.self)
        }

        // Pick the most common line ending, then normalize everything to "\n".
        var crlf = 0, lf = 0, cr = 0
        var previousWasCR = false
        for u in text.utf8 {
            if u == 0x0D { if previousWasCR { cr += 1 }; previousWasCR = true; continue }
            if u == 0x0A { if previousWasCR { crlf += 1 } else { lf += 1 } } else if previousWasCR { cr += 1 }
            previousWasCR = false
        }
        if previousWasCR { cr += 1 }
        if crlf > lf && crlf >= cr { format.lineEnding = .crlf } else if cr > lf && cr > crlf { format.lineEnding = .cr }
        if crlf + cr > 0 {
            text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        return (text, format)
    }

    public static func encode(_ text: String, format: FileFormat) throws -> Data {
        let withEndings = format.lineEnding == .lf
            ? text : text.replacingOccurrences(of: "\n", with: format.lineEnding.rawValue)
        guard var data = withEndings.data(using: format.encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        if format.encoding == .utf8 && format.hasBOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }
}
