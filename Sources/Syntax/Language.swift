import CTreeSitter
import TSGrammarBash
import TSGrammarC
import TSGrammarCss
import TSGrammarDiff
import TSGrammarGo
import TSGrammarHtml
import TSGrammarJava
import TSGrammarJavascript
import TSGrammarJson
import TSGrammarMarkdown
import TSGrammarMarkdownInline
import TSGrammarPython
import TSGrammarRust
import TSGrammarSwift
import TSGrammarTsx
import TSGrammarTypescript
import TSGrammarYaml

/// The languages Kite can color. Adding one: vendor its grammar, add a case here,
/// and copy its highlights.scm into Queries/.
public enum Language: String, CaseIterable, Sendable {
    case swift, python, javascript, json, typescript, tsx, markdown, shell, html, css, yaml, rust, go, c, java, diff
    /// Not a file type: the text inside Markdown paragraphs, parsed by `SyntaxTree` alongside `.markdown`.
    case markdownInline

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .python: "Python"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .markdown, .markdownInline: "Markdown"
        case .shell: "Shell"
        case .html: "HTML"
        case .css: "CSS"
        case .yaml: "YAML"
        case .rust: "Rust"
        case .go: "Go"
        case .c: "C"
        case .java: "Java"
        case .diff: "Diff"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .swift: ["swift"]
        case .python: ["py", "pyw", "pyi"]
        case .javascript: ["js", "mjs", "cjs", "jsx"]
        case .json: ["json", "jsonc"]
        case .typescript: ["ts", "mts", "cts"]
        case .tsx: ["tsx"]
        case .markdown: ["md", "markdown", "mdown", "mkd"]
        case .markdownInline: []
        case .shell: ["sh", "bash", "zsh"]
        case .html: ["html", "htm"]
        case .css: ["css"]
        case .yaml: ["yaml", "yml"]
        case .rust: ["rs"]
        case .go: ["go"]
        case .c: ["c", "h"]
        case .java: ["java"]
        case .diff: ["diff", "patch"]
        }
    }

    public var lineComment: String? {
        switch self {
        case .swift, .javascript, .typescript, .tsx, .rust, .go, .c, .java: "//"
        case .python, .shell, .yaml: "#"
        case .json, .markdown, .markdownInline, .html, .css, .diff: nil
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
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .shell: tree_sitter_bash()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .yaml: tree_sitter_yaml()
        case .rust: tree_sitter_rust()
        case .go: tree_sitter_go()
        case .c: tree_sitter_c()
        case .java: tree_sitter_java()
        case .diff: tree_sitter_diff()
        }
    }
}

/// What a highlighted piece of code is. The theme maps these to colors.
public enum TokenKind: Sendable, CaseIterable {
    case keyword, string, escape, comment, number, constant
    case function, builtin, type, property, parameter, variable
    case attribute, label, `operator`, punctuation, tag
    case added, removed   // diff lines

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
        "diff.plus": .added, "diff.minus": .removed,
    ]
}

public struct HighlightSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var kind: TokenKind
}
