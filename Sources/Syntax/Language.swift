import CTreeSitter
import TSGrammarJavascript
import TSGrammarJson
import TSGrammarPython
import TSGrammarSwift

/// The languages Kite can color. Adding one: vendor its grammar, add a case here,
/// and copy its highlights.scm into Queries/.
public enum Language: String, CaseIterable, Sendable {
    case swift, python, javascript, json

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .json: "JSON"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .swift: ["swift"]
        case .python: ["py", "pyw", "pyi"]
        case .javascript: ["js", "mjs", "cjs", "jsx"]
        case .json: ["json", "jsonc"]
        }
    }

    public var lineComment: String? {
        switch self {
        case .swift, .javascript: "//"
        case .python: "#"
        case .json: nil
        }
    }

    public static func forFileExtension(_ ext: String) -> Language? {
        let ext = ext.lowercased()
        return allCases.first { $0.fileExtensions.contains(ext) }
    }

    var tsLanguage: OpaquePointer {
        switch self {
        case .swift: tree_sitter_swift()
        case .python: tree_sitter_python()
        case .javascript: tree_sitter_javascript()
        case .json: tree_sitter_json()
        }
    }
}

/// What a highlighted piece of code is. The theme maps these to colors.
public enum TokenKind: Sendable, CaseIterable {
    case keyword, string, escape, comment, number, constant
    case function, builtin, type, property, parameter, variable
    case attribute, label, `operator`, punctuation, tag

    /// Maps a query capture name like "keyword.function" or "string.special.key".
    static func from(captureName name: String) -> TokenKind? {
        if let exact = exactNames[name] { return exact }
        var parts = name.split(separator: ".")
        while parts.count > 1 {
            parts.removeLast()
            if let kind = exactNames[parts.joined(separator: ".")] { return kind }
        }
        return nil
    }

    private static let exactNames: [String: TokenKind] = [
        "keyword": .keyword, "conditional": .keyword, "repeat": .keyword, "include": .keyword,
        "exception": .keyword,
        "string": .string, "string.regexp": .string, "string.special": .string,
        "string.special.key": .property,
        "string.escape": .escape, "escape": .escape, "character.special": .escape,
        "comment": .comment,
        "number": .number, "float": .number, "boolean": .constant,
        "constant": .constant, "constant.builtin": .constant,
        "function": .function, "method": .function, "function.builtin": .builtin,
        "type": .type, "constructor": .type,
        "variable.builtin": .builtin, "variable.parameter": .parameter, "parameter": .parameter,
        "variable.member": .property, "property": .property,
        "attribute": .attribute, "label": .label, "operator": .operator,
        "punctuation": .punctuation, "punctuation.special": .operator,
        "tag": .tag,
    ]
}

public struct HighlightSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var kind: TokenKind
}
