// swift-tools-version: 6.2
import PackageDescription

let grammarCSettings: [CSetting] = [
    .unsafeFlags(["-w", "-O2"]),  // vendored C: no warnings, always optimized
]

func grammar(_ name: String) -> Target {
    let title = name.prefix(1).uppercased() + name.dropFirst()
    return .target(
        name: "TSGrammar\(title)",
        path: "Vendor/grammars/\(name)",
        exclude: ["LICENSE"],
        sources: ["src"],
        publicHeadersPath: "include",
        cSettings: grammarCSettings + [.headerSearchPath("src")]
    )
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
        grammar("swift"),
        grammar("python"),
        grammar("javascript"),
        grammar("json"),

        // Parsing + highlight queries on top of EditorCore. No AppKit.
        .target(
            name: "Syntax",
            dependencies: [
                "EditorCore", "CTreeSitter",
                "TSGrammarSwift", "TSGrammarPython", "TSGrammarJavascript", "TSGrammarJson",
            ],
            resources: [.copy("Queries")]
        ),

        // The macOS app.
        .executableTarget(
            name: "Kite",
            dependencies: ["EditorCore", "Syntax"]
        ),

        .testTarget(name: "EditorCoreTests", dependencies: ["EditorCore"]),
        .testTarget(name: "SyntaxTests", dependencies: ["Syntax"]),
    ]
)
