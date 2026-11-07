import AppKit
import EditorCore
import Syntax

/// Command-line tools for checking the editor without a screen:
///   Kite --render <file> <out.png> [--dark|--light] [--line N] [--select A:B] [--size WxH] [--wrap] [--project DIR] [--quick-open QUERY] [--search QUERY] [--cursors A,B,…]
///   Kite --bench <file>
enum DevTools {
    @MainActor
    static func handle(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--render"), i + 2 < args.count {
            render(file: args[i + 1], output: args[i + 2], args: args)
            return true
        }
        if let i = args.firstIndex(of: "--selftest-save"), i + 1 < args.count {
            selfTestSave(path: args[i + 1])
            return true
        }
        if let i = args.firstIndex(of: "--bench"), i + 1 < args.count {
            bench(file: args[i + 1])
            return true
        }
        return false
    }

    private static func value(_ args: [String], _ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    @MainActor
    private static func load(_ path: String) -> (TextEditor, Language?) {
        let url = URL(fileURLWithPath: path)
        let data = (try? Data(contentsOf: url)) ?? Data()
        let editor = TextEditor(buffer: TextBuffer(TextFileCodec.decode(data).text))
        return (editor, Language.forFileExtension(url.pathExtension))
    }

    @MainActor
    private static func render(file: String, output: String, args: [String]) {
        let (editor, language) = load(file)
        if let folder = value(args, "--project") {
            Project.pendingForNewWindow = Project.open(URL(fileURLWithPath: folder))
        }
        let controller = EditorWindowController(document: nil, editor: editor, language: language,
                                                fileURL: URL(fileURLWithPath: file).standardizedFileURL)
        Project.pendingForNewWindow = nil
        controller.revealInSidebar(URL(fileURLWithPath: file))
        let window = controller.window!
        window.appearance = NSAppearance(named: args.contains("--light") ? .aqua : .darkAqua)
        let size = value(args, "--size")?.split(separator: "x").compactMap { Double($0) } ?? []
        window.setContentSize(NSSize(width: size.first ?? 900, height: size.dropFirst().first ?? 640))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = controller.editorView
        view.viewDidChangeEffectiveAppearance()
        view.syntax?.parseSynchronously()
        if args.contains("--wrap") { view.wordWrap = true }
        view.updateFrameSize()

        if let s = value(args, "--select")?.split(separator: ":").compactMap({ Int($0) }), s.count == 2 {
            editor.setSelection(Selection(anchor: s[0], head: s[1]))
        }
        if let list = value(args, "--cursors")?.split(separator: ",").compactMap({ Int($0) }), let first = list.first {
            editor.setSelection(Selection(caret: first))
            for offset in list.dropFirst() { editor.addSelection(Selection(caret: offset)) }
        }
        if let line = value(args, "--line").flatMap(Int.init) {
            view.scroll(NSPoint(x: 0, y: view.lineTop(max(line - 1, 0))))
        }
        if let query = value(args, "--find") { view.findQuery = query }

        var content = window.contentView!
        if let query = value(args, "--search") {
            // Wait for the file list, search, and give the background search a moment to finish.
            let deadline = Date().addingTimeInterval(5)
            while let project = controller.project, !project.isIndexed, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            controller.searchProjectForDevTools(query)
            RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        }
        if let query = value(args, "--quick-open") {
            // Wait for the project's file list, then show ⌘P with the query typed in.
            let deadline = Date().addingTimeInterval(5)
            while let project = controller.project, !project.isIndexed, Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            controller.quickOpen(nil)
            if let panel = QuickOpenPanel.renderedForDevTools(query: query) { content = panel }
        }
        content.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["KITE_DEBUG_LAYOUT"] != nil {
            func dump(_ v: NSView, _ depth: Int) {
                guard depth < 6 else { return }
                print(String(repeating: "  ", count: depth) + String(describing: type(of: v)), v.frame, v.isHidden ? "hidden" : "")
                for sub in v.subviews { dump(sub, depth + 1) }
            }
            dump(content, 0)
        }
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        print("rendered \(output)")
    }

    /// Opens a file as a real document, edits it through the editor, saves, and checks the result.
    @MainActor
    private static func selfTestSave(path: String) {
        func check(_ ok: Bool, _ label: String) { print(ok ? "PASS" : "FAIL", label) }
        let url = URL(fileURLWithPath: path)
        let original = try! Data(contentsOf: url)
        guard let doc = try? TextDocument(contentsOf: url, ofType: "Text") else { print("FAIL open"); return }
        doc.makeWindowControllers()
        let controller = doc.windowControllers.first as! EditorWindowController
        let view = controller.editorView
        let e = doc.editor
        check(view.syntax != nil, "syntax coloring active for .\(url.pathExtension)")
        check(!doc.isDocumentEdited && !e.isDirty, "clean after open")
        e.setSelection(Selection(caret: 0))
        e.insertText("// saved by Kite")
        e.insertNewline()
        check(doc.isDocumentEdited, "window shows unsaved changes after typing")
        e.undo(); e.undo()
        check(!doc.isDocumentEdited, "undo back to saved state clears the unsaved mark")
        e.redo(); e.redo()
        var done = false
        doc.save(to: url, ofType: "Text", for: .saveOperation) { error in
            if let error { print("save error:", error) }
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(!doc.isDocumentEdited && !e.isDirty, "clean after save")
        let saved = try! Data(contentsOf: url)
        let expected = Data("// saved by Kite\r\n".utf8) + original
        check(saved == expected, "file on disk = edit + original bytes, CRLF kept (\(doc.format.lineEnding.label))")

        // Revert to Saved must reload into the editor the window is showing.
        e.insertText("junk")
        try? doc.revert(toContentsOf: url, ofType: "Text")
        check(doc.editor === view.editor && e.text == String(decoding: saved, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n"),
              "revert reloads the text the window is showing")
        check(!doc.isDocumentEdited, "clean after revert")

        // Drive the real keyboard path: keyDown → interpretKeyEvents → insertText / doCommand.
        let window = view.window!
        window.makeFirstResponder(view)
        func key(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: chars,
                                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            view.keyDown(with: event)
        }
        e.resetText("x = 1")
        e.setSelection(Selection(caret: 5))
        key("2", 19)
        check(e.text == "x = 12", "typing a key inserts it (got \(e.text.debugDescription))")
        key("\u{7f}", 51)
        check(e.text == "x = 1", "Delete key removes a character")
        key(String(Character(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!)), 123, [.option, .function, .numericPad])
        check(e.caret == 4, "⌥← jumps a word (caret \(e.caret))")
        key("\r", 36)
        check(e.text == "x = \n1", "Return inserts a newline (got \(e.text.debugDescription))")
        // Input methods: accent composition through the text-input protocol.
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        check(view.hasMarkedText(), "input method shows composing text")
        view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(e.text == "x = \né1" && !view.hasMarkedText(), "composed accent is committed (got \(e.text.debugDescription))")
        check(view.selectedRange() == NSRange(location: 6, length: 0), "UTF-16 caret position reported to macOS")

        // Soft wrap: ↓ walks the rows of a long line before reaching the next line.
        let wasWrapping = view.wordWrap
        e.resetText(String(repeating: "word ", count: 60) + "\nend")
        view.wordWrap = true
        view.updateFrameSize()
        e.setSelection(Selection(caret: 2))
        let down = String(Character(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!))
        key(down, 125, [.function, .numericPad])
        check(e.caret > 2 && e.caret < 300, "↓ with wrap moves to the next row of the same line (caret \(e.caret))")
        var presses = 1
        while e.buffer.line(containing: e.caret) == 0 && presses < 40 {
            key(down, 125, [.function, .numericPad]); presses += 1
        }
        check(e.buffer.line(containing: e.caret) == 1 && presses > 2,
              "repeated ↓ walks every row, then reaches the next line (\(presses) presses)")
        view.wordWrap = wasWrapping

        // Multiple cursors: ⌘D twice, type, ⌥-click adds one, Esc collapses.
        e.resetText("foo bar foo")
        e.setSelection(Selection(caret: 1))
        view.addNextOccurrence(nil)
        view.addNextOccurrence(nil)
        key("x", 7)
        check(e.text == "x bar x", "⌘D twice then typing changes both matches (got \(e.text.debugDescription))")
        e.setSelection(Selection(caret: 0))
        let target = view.caretRect(for: 4)
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(NSPoint(x: target.midX, y: target.midY), to: nil),
                                       modifierFlags: .option, timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: click)
        check(e.allSelections.map(\.head) == [0, 4], "⌥-click adds a second cursor (cursors at \(e.allSelections.map(\.head)))")
        key("\u{1b}", 53)
        check(!e.hasMultipleCursors, "Esc goes back to one cursor")

        // Tabs: a second file opens as a tab in the same window, with its own editor.
        let secondURL = url.deletingLastPathComponent().appendingPathComponent("kite-selftest-second.txt")
        try? "second file\n".write(to: secondURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: secondURL) }
        if let second = try? TextDocument(contentsOf: secondURL, ofType: "Text") {
            controller.addTab(for: second)
            check(controller.panes.count == 2 && controller.editorView.editor === second.editor,
                  "a second file opens as a tab with its own editor")
            check(second.windowControllers.contains(controller) && !doc.windowControllers.contains(controller),
                  "the window belongs to the active tab's document")
            controller.editorView.editor.insertText("!")
            check(e.text == "x bar x", "typing in one tab leaves the other file alone")
            controller.activate(document: doc)
            check(controller.editorView.editor === e, "switching back shows the first file again")
            second.editor.undo()
            controller.closeTab(1)
            check(controller.panes.count == 1 && controller.window != nil && controller.editorView.editor === e,
                  "closing a tab keeps the window and the other tab")
        } else {
            check(false, "could open a second file")
        }
    }

    @MainActor
    private static func bench(file: String) {
        func time(_ label: String, _ body: () -> Void) {
            let start = ContinuousClock.now
            body()
            let d = ContinuousClock.now - start
            let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
            print(String(format: "%-34@ %9.2f ms", label as NSString, ms))
        }
        let url = URL(fileURLWithPath: file)
        var data = Data()
        var text = ""
        var editor = TextEditor()
        time("read file") { data = (try? Data(contentsOf: url)) ?? Data() }
        time("decode") { text = TextFileCodec.decode(data).text }
        time("build buffer + line index") { editor = TextEditor(buffer: TextBuffer(text)) }
        print("  \(editor.buffer.byteCount) bytes, \(editor.buffer.lineCount) lines")

        let language = Language.forFileExtension(url.pathExtension)
        let controller = EditorWindowController(document: nil, editor: editor, language: nil)
        let window = controller.window!
        window.setContentSize(NSSize(width: 1200, height: 900))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = controller.editorView
        var syntax: SyntaxTree?
        time("first parse (\(language?.displayName ?? "none"))") {
            syntax = language.flatMap { SyntaxTree(language: $0, buffer: editor.buffer) }
            syntax?.parseSynchronously()
        }
        view.syntax = syntax
        view.updateFrameSize()
        // Draw only the editor view, so we time our drawing rather than window chrome.
        let content = view
        let rep = view.bitmapImageRepForCachingDisplay(in: view.visibleRect)!
        time("draw first screen") { content.cacheDisplay(in: view.visibleRect, to: rep) }

        // Jump to the middle and type, redrawing after each keystroke like the real app does.
        let middle = editor.buffer.lineCount / 2
        view.scroll(NSPoint(x: 0, y: view.lineTop(middle)))
        editor.setSelection(Selection(caret: editor.buffer.lineStarts[middle]))
        content.cacheDisplay(in: view.visibleRect, to: rep)
        var worst: Duration = .zero
        let keys = 200
        time("type \(keys) chars mid-file (+ redraw)") {
            for i in 0..<keys {
                let t0 = ContinuousClock.now
                if i % 40 == 39 { editor.insertNewline() } else { editor.insertText("x") }
                content.cacheDisplay(in: view.visibleRect, to: rep)
                worst = max(worst, ContinuousClock.now - t0)
            }
        }
        let worstMs = Double(worst.components.attoseconds) / 1e15 + Double(worst.components.seconds) * 1000
        print(String(format: "  worst single keystroke: %.2f ms", worstMs))
        if let syntax {
            time("colors catch up after typing") {
                while !syntax.isUpToDate { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
            }
        }
        time("scroll through 50 screens") {
            for i in 0..<50 {
                view.scroll(NSPoint(x: 0, y: view.lineTop(min(i * 60, editor.buffer.lineCount - 1))))
                content.cacheDisplay(in: view.visibleRect, to: rep)
            }
        }
    }
}
