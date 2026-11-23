// swift-tools-version: 6.2
import PackageDescription

let grammarCSettings: [CSetting] = [
    .unsafeFlags(["-w", "-O2"]),  // vendored C: no warnings, always optimized
]

func grammar(_ name: String, exclude: [String] = []) -> Target {
    let title = name.prefix(1).uppercased() + name.dropFirst()
    return .target(
        name: "TSGrammar\(title)",
        path: "Vendor/grammars/\(name)",
        exclude: ["LICENSE"] + exclude,
        sources: ["src"],
        publicHeadersPath: "include",
        cSettings: grammarCSettings + [.headerSearchPath("src")]
    )
}

/// Every grammar Kite is built with, by its folder in Vendor/grammars.
let grammarNames = [
    "swift", "python", "javascript", "json", "typescript", "tsx", "markdown", "markdownInline",
    "bash", "html", "css", "yaml", "rust", "go", "c", "java", "diff",
]

func grammarTarget(_ name: String) -> Target.Dependency {
    .target(name: "TSGrammar" + name.prefix(1).uppercased() + name.dropFirst())
}

let package = Package(
    name: "Kite",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Kite", targets: ["Kite"]),
    ],
    targets: [
        // Text buffer, selections, editing commands, undo. No AppKit.
        .target(name: "EditorCore"),

        // Tree-sitter core, vendored at v0.27.1.
        .target(
            name: "CTreeSitter",
            path: "Vendor/tree-sitter",
            exclude: ["LICENSE"],
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: grammarCSettings + [.headerSearchPath("src")]
        ),

        // Parsing + highlight queries on top of EditorCore. No AppKit.
        .target(
            name: "Syntax",
            dependencies: ["EditorCore", "CTreeSitter"] + grammarNames.map(grammarTarget),
            resources: [.copy("Queries")]
        ),

        // Markdown files as blocks with their source lines, for the preview. Foundation only.
        .target(name: "Markdown"),

        // The macOS app.
        .executableTarget(
            name: "Kite",
            dependencies: ["EditorCore", "Syntax", "Markdown"]
        ),

        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "SyntaxTests", dependencies: ["Syntax"]),
        .testTarget(name: "MarkdownTests", dependencies: ["Markdown"]),
    ] + grammarNames.map {
        // YAML's scanner #includes its schema file, so it isn't compiled on its own.
        grammar($0, exclude: $0 == "yaml" ? ["src/schema.core.c"] : [])
    }
)
