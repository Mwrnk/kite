import CTreeSitter
import EditorCore

/// A declaration in a file: a type, function, method or key, found from the parse tree alone
/// (no language server needed).
public struct Symbol: Sendable, Equatable {
    /// How the language spells it: "struct", "func", "def", "class", "method", "key"…
    public let kind: String
    public let name: String
    /// The whole declaration, and just its name.
    public let range: Range<Int>
    public let nameRange: Range<Int>
    /// How many symbols it's nested in (a method in a class is 1).
    public let depth: Int
}

extension SyntaxTree {
    /// Every declaration in the file, in order. Parses first if no tree is ready yet.
    public func symbols() -> [Symbol] {
        if tree == nil { parseSynchronously() }
        guard let tree else { return [] }
        var out: [Symbol] = []
        // Depth-first with an explicit stack: deeply nested files can't overflow it.
        var stack: [(TSNode, Int)] = [(ts_tree_root_node(tree.pointer), 0)]
        while let (node, depth) = stack.popLast() {
            var childDepth = depth
            if let symbol = symbol(for: node, depth: depth) {
                out.append(symbol)
                childDepth = depth + 1
            }
            let count = ts_node_named_child_count(node)
            guard count > 0, descends(into: node) else { continue }
            for i in (0..<count).reversed() { stack.append((ts_node_named_child(node, i), childDepth)) }
        }
        return out
    }

    /// The declarations the offset is inside, outermost first ("Point", "move").
    public func enclosingSymbols(at offset: Int) -> [Symbol] {
        guard let tree else { return [] }
        let at = UInt32(max(0, min(offset, buffer.byteCount)))
        var node = ts_node_named_descendant_for_byte_range(ts_tree_root_node(tree.pointer), at, at)
        var found: [Symbol] = []
        while !ts_node_is_null(node) {
            if let symbol = symbol(for: node, depth: 0) { found.append(symbol) }
            node = ts_node_parent(node)
        }
        return found.reversed()
    }

    /// The syntax nodes around `range`, smallest first, each strictly bigger than the one before:
    /// a word, its call, the statement, the block, the function… (expand selection).
    public func enclosingRanges(of range: Range<Int>) -> [Range<Int>] {
        if tree == nil { parseSynchronously() }
        guard let tree else { return [] }
        let lo = UInt32(max(0, min(range.lowerBound, buffer.byteCount)))
        let hi = UInt32(max(0, min(range.upperBound, buffer.byteCount)))
        var node = ts_node_named_descendant_for_byte_range(ts_tree_root_node(tree.pointer), lo, hi)
        var out: [Range<Int>] = []
        while !ts_node_is_null(node) {
            let r = Int(ts_node_start_byte(node))..<Int(ts_node_end_byte(node))
            if r.lowerBound <= range.lowerBound, r.upperBound >= range.upperBound, r != range, out.last != r {
                out.append(r)
            }
            node = ts_node_parent(node)
        }
        return out
    }

    // MARK: Rules per language

    private func type(_ node: TSNode) -> String { String(cString: ts_node_type(node)) }

    private func range(_ node: TSNode) -> Range<Int> { Int(ts_node_start_byte(node))..<Int(ts_node_end_byte(node)) }

    private func field(_ node: TSNode, _ name: String) -> TSNode? {
        let child = name.withCString { ts_node_child_by_field_name(node, $0, UInt32(name.utf8.count)) }
        return ts_node_is_null(child) ? nil : child
    }

    /// The first unnamed child whose text is one of `words` (Swift's `struct`, `class`, …).
    private func keyword(of node: TSNode, among words: Set<String>) -> (String, TSNode)? {
        for i in 0..<ts_node_child_count(node) {
            let child = ts_node_child(node, i)
            let t = type(child)
            if words.contains(t) { return (t, child) }
        }
        return nil
    }

    /// Strings and comments can't hold declarations; skip them.
    private func descends(into node: TSNode) -> Bool {
        switch type(node) {
        case "comment", "string", "line_string_literal", "multi_line_string_literal", "template_string": false
        default: true
        }
    }

    private func make(_ kind: String, _ node: TSNode, name nameNode: TSNode?, depth: Int) -> Symbol? {
        guard let nameNode else { return nil }
        let nameRange = range(nameNode)
        var name = buffer.string(in: nameRange)
        if let newline = name.firstIndex(of: "\n") { name = String(name[..<newline]) }
        guard !name.isEmpty else { return nil }
        return Symbol(kind: kind, name: name, range: range(node), nameRange: nameRange, depth: depth)
    }

    func symbol(for node: TSNode, depth: Int) -> Symbol? {
        let t = type(node)
        switch language {
        case .swift:
            switch t {
            case "class_declaration":
                let kind = keyword(of: node, among: ["class", "struct", "enum", "extension", "actor"])?.0 ?? "type"
                return make(kind, node, name: field(node, "name"), depth: depth)
            case "protocol_declaration": return make("protocol", node, name: field(node, "name"), depth: depth)
            case "function_declaration", "protocol_function_declaration":
                return make("func", node, name: field(node, "name"), depth: depth)
            case "init_declaration": return make("init", node, name: keyword(of: node, among: ["init"])?.1, depth: depth)
            case "typealias_declaration": return make("typealias", node, name: field(node, "name"), depth: depth)
            default: return nil
            }
        case .python:
            switch t {
            case "class_definition": return make("class", node, name: field(node, "name"), depth: depth)
            case "function_definition": return make("def", node, name: field(node, "name"), depth: depth)
            default: return nil
            }
        case .javascript:
            switch t {
            case "class_declaration", "class": return make("class", node, name: field(node, "name"), depth: depth)
            case "function_declaration", "generator_function_declaration":
                return make("function", node, name: field(node, "name"), depth: depth)
            case "method_definition": return make("method", node, name: field(node, "name"), depth: depth)
            case "variable_declarator":
                guard let value = field(node, "value"),
                      ["arrow_function", "function_expression", "function", "generator_function"].contains(type(value)) else { return nil }
                return make("function", node, name: field(node, "name"), depth: depth)
            default: return nil
            }
        case .json:
            // Top-level keys only: deeper ones would bury the outline.
            guard t == "pair", let object = Optional(ts_node_parent(node)), !ts_node_is_null(object),
                  type(object) == "object", type(ts_node_parent(object)) == "document" else { return nil }
            return make("key", node, name: field(node, "key"), depth: depth)
        }
    }
}
