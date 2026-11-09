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

    /// Saves the front window, as drawn, to a PNG.
    @MainActor
    static func snapshotFrontWindow(to path: String) {
        guard let view = NSApp.orderedWindows.first?.contentView?.superview ?? NSApp.orderedWindows.first?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        layer.render(in: ctx.cgContext)   // the bitmap context is already at the screen's scale
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Sends a key press through the app, as if typed (so menus and field editors see it).
    @MainActor
    static func press(_ keyCode: UInt16, option: Bool, in window: NSWindow?) {
        guard let window else { return }
        let chars = keyCode == 36 ? "\r" : ""
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: option ? [.option] : [],
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                            isARepeat: false, keyCode: keyCode) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Runs `steps` one after another, `gap` seconds apart (each may wait on background work).
    @MainActor
    static func run(_ steps: [() -> Void], gap: TimeInterval = 0.3, then done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first()
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            MainActor.assumeIsolated { run(Array(steps.dropFirst()), gap: gap, then: done) }
        }
    }

    /// KITE_TEST_SCRIPT=<name>: drives the running app for end-to-end checks, then quits normally.
    ///   edit-and-quit  types into the front file, moves the cursor, quits (must not ask to save)
    ///   report         prints the windows, tabs, unsaved state and cursors, then quits
    @MainActor
    static func runTestScript(_ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                switch name {
                case "edit-and-quit":
                    // The front tab: an unsaved line, a selection plus two more cursors, scrolled down.
                    if let c = EditorWindowController.all.first {
                        let view = c.editorView
                        view.editor.setSelection(Selection(caret: 0))
                        view.editor.insertText("# unsaved line\n")
                        view.editor.setSelection(Selection(anchor: 4, head: 10))
                        view.editor.addSelection(Selection(caret: 20))
                        view.editor.addSelection(Selection(caret: 30))
                        view.editor.addSelection(Selection(anchor: 4, head: 10))   // back to main
                        view.scroll(NSPoint(x: 0, y: 200))
                        // And a new untitled tab with some text.
                        NSDocumentController.shared.newDocument(nil)
                        c.editorView.editor.insertText("scratch notes")
                        c.window?.setFrame(NSRect(x: 120, y: 140, width: 1000, height: 650), display: false)
                    }
                    print("edited; quitting")
                case "report":
                    for c in EditorWindowController.all {
                        print("window project=\(c.project?.name ?? "none") tabs=\(c.panes.count) frame=\(NSStringFromRect(c.window?.frame ?? .zero))")
                        for p in c.panes {
                            let s = p.editor.selection
                            let extras = p.editor.extraSelections.map { "\($0.anchor)-\($0.head)" }.joined(separator: ",")
                            let y = p.pendingScrollY ?? p.scrollView.contentView.bounds.origin.y
                            print("  tab \(p.title) dirty=\(p.document?.isDocumentEdited ?? false) selection=\(s.anchor)-\(s.head) extra=[\(extras)] scrollY=\(y) first=\(p.editor.buffer.lineString(0).debugDescription) active=\(p === c.panes.first { $0.editorView === c.editorView })")
                        }
                    }
                case "find":
                    runFindScript()
                    return
                case "project-replace":
                    runProjectReplaceScript()
                    return
                case "note-recent":
                    // Adds KITE_TEST_FILE to the recent files and redraws the start window (stays open).
                    if let path = ProcessInfo.processInfo.environment["KITE_TEST_FILE"] {
                        NSDocumentController.shared.noteNewRecentDocumentURL(URL(fileURLWithPath: path))
                    }
                    StartWindow.show()
                    return
                case "start-return":
                    // Press Return in the start window, then report what's open a moment later.
                    let start = NSApp.windows.first { $0.windowController is StartWindow }
                    print("start window shown=\(start?.isVisible ?? false)")
                    if let start, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                               windowNumber: start.windowNumber, context: nil, characters: "\r",
                                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                        start.sendEvent(event)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MainActor.assumeIsolated {
                            let still = NSApp.windows.contains { $0.windowController is StartWindow && $0.isVisible }
                            print("after return: start window shown=\(still) editor windows=\(EditorWindowController.all.map { $0.project?.name ?? "none" })")
                            NSApp.terminate(nil)
                        }
                    }
                    return
                default: print("unknown test script \(name)")
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// KITE_TEST_SCRIPT=find: drives the find bar in the front window. Expects a file with
    /// "foo fooo bar\nfoo baz\nlast foo\n" open. Prints PASS/FAIL lines, then quits.
    @MainActor
    private static func runFindScript() {
        guard let c = EditorWindowController.all.first else { print("FAIL no window"); NSApp.terminate(nil); return }
        let bar = c.findBar
        let editor = c.editorView.editor
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        let original = editor.text
        func selected() -> String { editor.selectedText }
        DevTools.run([
            { editor.setSelection(Selection(caret: 0)); bar.show(replacing: true); bar.type("foo") },
            {
                check(bar.countText == "1 of 4", "typing finds and selects the first match (\(bar.countText))")
                check(selected() == "foo", "first match selected")
                bar.findNext(nil)
            },
            {
                check(editor.selection.range == 4..<7, "⌘G goes to the next match")
                check(bar.countText == "2 of 4", "count follows (\(bar.countText))")
                bar.toggleWord(nil)
            },
            {
                check(bar.countText.hasSuffix("3 matches"), "whole word skips fooo (\(bar.countText))")
                bar.toggleWord(nil)
                bar.toggleRegex(nil)
                bar.type("f(o+)")
            },
            {
                editor.setSelection(Selection(anchor: 4, head: 8))   // "fooo"
                bar.replaceField.stringValue = "<$1>"
                bar.replaceCurrent(nil)
            },
            {
                check(editor.text.hasPrefix("foo <ooo> bar"), "replace uses $1 on the current match")
                check(editor.selection.range == 14..<17, "replace goes on to the next match (\(editor.selection.range))")
                bar.replaceAll(nil)
            },
            {
                check(editor.text == "<oo> <ooo> bar\n<oo> baz\nlast <oo>\n", "replace all (\(editor.text.debugDescription))")
                editor.undo()
                editor.undo()
                check(editor.text == original, "two undos get back the original")
                bar.type("^")
                bar.replaceField.stringValue = "// "
            },
            { bar.replaceAll(nil) },
            {
                check(editor.text == "// foo fooo bar\n// foo baz\n// last foo\n", "^ prefixes every line, not the end of the file (\(editor.text.debugDescription))")
                editor.undo()
                // Find in selection: lines 2 and 3 only.
                editor.setSelection(Selection(anchor: 13, head: original.utf8.count - 1))
                bar.type("foo")
                bar.toggleSelection(nil)
                bar.replaceField.stringValue = "X"
                bar.toggleRegex(nil)
            },
            { bar.replaceAll(nil) },
            {
                check(editor.text == "foo fooo bar\nX baz\nlast X\n", "replace all stays in the selection (\(editor.text.debugDescription))")
                editor.undo()
                bar.toggleSelection(nil)
                editor.setSelection(Selection(caret: 0))
                bar.selectAllMatches(nil)
            },
            {
                check(editor.allSelections.count == 4, "select all matches makes 4 cursors (\(editor.allSelections.count))")
                editor.setSelection(Selection(caret: 0))
                bar.toggleRegex(nil)
                bar.type("(")
            },
            {
                check(bar.countText == "bad regex", "a broken regex shows in the count (\(bar.countText))")
                bar.type("ba")
            },
            {
                check(bar.countText.contains("2"), "two matches of ba (\(bar.countText))")
                let state = c.editorView.findState!
                let before = state.matches
                editor.setSelection(Selection(caret: 0))
                editor.insertText("ba ")   // typing in the code while find is open
                check(state.matches == before.map { ($0.lowerBound + 3)..<($0.upperBound + 3) }, "matches move with an edit before them")
                let hit = state.matches[0]
                editor.setSelection(Selection(caret: hit.lowerBound + 1))
                editor.insertText("Q")
                check(!state.matches.contains { $0.lowerBound == hit.lowerBound } && state.matches.count == before.count - 1,
                      "an edit inside a match drops it until the recount")
                editor.undo()
            },
            {
                check(bar.countText.contains("3"), "count follows edits (\(bar.countText))")
                bar.toggleRegex(nil)
                bar.type("foo")
                editor.setSelection(Selection(caret: 0))
                bar.findNext(nil)
            },
            {
                // Real keys: ⌥Return in the find field puts a cursor on every match.
                editor.setSelection(Selection(caret: 0))
                c.window?.makeFirstResponder(bar.findField)
                DevTools.press(36, option: true, in: c.window)
            },
            {
                check(editor.allSelections.count == 4, "⌥Return in find makes a cursor per match (\(editor.allSelections.count))")
                editor.setSelection(Selection(caret: 0))
                bar.findNext(nil)
            },
            {
                c.window?.makeFirstResponder(bar.replaceField)
                bar.replaceField.stringValue = "Z"
                DevTools.press(36, option: false, in: c.window)
            },
            {
                check(editor.text.hasPrefix("ba Z fooo"), "Return in replace replaces this match (\(editor.text.prefix(12).debugDescription))")
                DevTools.press(36, option: true, in: c.window)
            },
            {
                check(!editor.text.contains("foo"), "⌥Return in replace replaces all (\(editor.text.debugDescription))")
                if let path = ProcessInfo.processInfo.environment["KITE_SNAPSHOT"] { DevTools.snapshotFrontWindow(to: path) }
            },
        ], gap: 0.4) {
            print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
            for doc in NSDocumentController.shared.documents { doc.updateChangeCount(.changeCleared) }
            NSApp.terminate(nil)
        }
    }

    /// KITE_TEST_SCRIPT=project-replace: expects Kite opened on the folder made by the test
    /// (a.swift, b.swift with CRLF, c.txt, open.swift open with an unsaved edit, many/ with 25 files).
    @MainActor
    private static func runProjectReplaceScript() {
        guard let c = EditorWindowController.all.first(where: { $0.projectSidebar != nil }), let sidebar = c.projectSidebar,
              let root = c.project?.root else { print("FAIL no project window"); NSApp.terminate(nil); return }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print("\(ok ? "PASS" : "FAIL") \(what)")
            if !ok { failures += 1 }
        }
        func disk(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "?" }
        func doc(_ name: String) -> TextDocument? {
            NSDocumentController.shared.documents.compactMap { $0 as? TextDocument }.first { $0.fileURL?.lastPathComponent == name }
        }
        sidebar.showSearch()
        let search = sidebar.search
        // An unsaved edit in the open file: project search should see it.
        if let open = doc("open.swift") { open.editor.setSelection(Selection(caret: 0)); open.editor.insertText("fetchUser()\n") }
        let originalC = disk("c.txt")
        DevTools.run([
            { search.testSearch("fetchUser", replace: "loadUser") },
            {
                let files = search.testFiles.sorted { $0.name < $1.name }.map { "\($0.name):\($0.count)" }.joined(separator: " ")
                check(files == "a.swift:2 b.swift:1 c.txt:1 open.swift:1", "search finds every file, unsaved text too (\(files))")
                search.testSkip(file: "c.txt")
                check(search.testButton == "replace 4 in 3 files", "skipping a file updates the button (\(search.testButton))")
                search.testReplace()
            },
            {
                check(search.testStatus.hasPrefix("Replaced 4 in 3 files"), "report (\(search.testStatus))")
                check(c.panes.contains { $0.document?.fileURL?.lastPathComponent == "a.swift" }, "a.swift opened as a tab")
                check(doc("a.swift")?.isDocumentEdited == true && disk("a.swift").contains("fetchUser"), "a.swift is changed in memory, not on disk yet")
                check(doc("a.swift")?.editor.text == "loadUser(id)\nlet x = loadUser(me)\n", "a.swift text")
                check(doc("open.swift")?.editor.text.hasPrefix("loadUser()\n") == true, "the open file was changed in its tab")
                check(disk("c.txt") == originalC, "skipped file untouched")
                doc("a.swift")?.editor.undo()
                check(doc("a.swift")?.editor.text == "fetchUser(id)\nlet x = fetchUser(me)\n", "one undo step per file")
                doc("a.swift")?.editor.redo()
                c.saveAllFiles(nil)
            },
            {
                check(disk("a.swift") == "loadUser(id)\nlet x = loadUser(me)\n", "Save All wrote a.swift")
                let b = (try? Data(contentsOf: root.appendingPathComponent("b.swift"))) ?? Data()
                check(b == Data("x = loadUser()\r\ny = 2\r\n".utf8), "b.swift keeps CRLF")
                // A file changed on disk after the search is left alone.
                search.testSearch("keep", replace: "KEEP")
            },
            {
                try? "keep it changed\n".write(to: root.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
                search.testReplace()
            },
            {
                check(search.testStatus.contains("changed since the search"), "changed file reported (\(search.testStatus))")
                check(disk("c.txt") == "keep it changed\n", "changed file left alone")
                // Over 20 files: saved straight to disk (the confirm sheet is skipped here).
                search.testSearch("needle", replace: "pin")
            },
            {
                check(search.testButton == "replace 25 in 25 files", "25 files found (\(search.testButton))")
                let plans = (0..<25).map { i in
                    ProjectReplace.FilePlan(url: root.appendingPathComponent("many/f\(i).txt"), previewed: [4], skip: [])
                }
                let query = try! FindQuery("needle")
                ProjectReplace.run(plans, query: query, template: "pin", saving: true, in: c) { search.refresh(notice: $0) }
            },
            {
                check(disk("many/f7.txt") == "one pin two\n", "saved straight to disk")
                check(ProjectReplace.lastSaved.count == 25, "originals kept for undo")
                check(!c.panes.contains { $0.document?.fileURL?.path.contains("/many/") == true }, "no tabs for a big replace")
                c.undoReplaceInFiles(nil)
            },
            {
                check(disk("many/f7.txt") == "one needle two\n", "Undo Replace in Files put them back")
                check(search.testStatus.hasPrefix("Put back 25 files"), "undo report (\(search.testStatus))")
                if let path = ProcessInfo.processInfo.environment["KITE_SNAPSHOT"] {
                    search.testSearch("loadUser", replace: "getUser")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        MainActor.assumeIsolated { DevTools.snapshotFrontWindow(to: path) }
                    }
                }
            },
            {},
            {},
        ], gap: 0.5) {
            print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
            for d in NSDocumentController.shared.documents { d.updateChangeCount(.changeCleared) }
            NSApp.terminate(nil)
        }
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
        if let pattern = value(args, "--find") {
            // --regex and --find-in A:B work with it; matches are counted right here.
            let query = try? FindQuery(pattern, options: FindOptions(regex: args.contains("--regex")))
            let state = view.findState ?? FindState(buffer: editor.buffer)
            view.findState = state
            if let s = value(args, "--find-in")?.split(separator: ":").compactMap({ Int($0) }), s.count == 2 {
                state.scope = s[0]..<s[1]
            }
            state.show(query?.matches(in: editor.text, within: state.scope) ?? [])
            view.showsFind = true
        }

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

        // The same typing with find open on a busy regex: matches move with each edit and are
        // counted again in the background.
        view.scroll(NSPoint(x: 0, y: view.lineTop(middle)))
        let find = controller.findBar
        let state = view.findState!
        time("count matches of \\w+\\( (background)") {
            find.show(replacing: false)
            find.toggleRegex(nil)
            find.type("\\w+\\(")
            let deadline = Date().addingTimeInterval(20)
            while !state.isFresh && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.001)) }
        }
        print("  \(state.matches.count)\(state.capped ? "+" : "") matches")
        editor.setSelection(Selection(caret: editor.buffer.lineStarts[middle]))
        content.cacheDisplay(in: view.visibleRect, to: rep)
        worst = .zero
        time("type \(keys) chars, find open (+ redraw)") {
            for i in 0..<keys {
                let t0 = ContinuousClock.now
                if i % 40 == 39 { editor.insertNewline() } else { editor.insertText("x") }
                content.cacheDisplay(in: view.visibleRect, to: rep)
                let d = ContinuousClock.now - t0
                worst = max(worst, d)
                if ProcessInfo.processInfo.environment["KITE_BENCH_DEBUG"] != nil, d > .milliseconds(4) { print("  slow key \(i): \(d)") }
                if i % 20 == 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }   // let counts land between bursts
            }
        }
        let worstFindMs = Double(worst.components.attoseconds) / 1e15 + Double(worst.components.seconds) * 1000
        print(String(format: "  worst keystroke, find open: %.2f ms", worstFindMs))

        // Replace every match, undo it, then put a cursor on every match and type.
        let query = try! FindQuery("\\w+\\(", options: FindOptions(regex: true))
        let edits = query.replacements(in: editor.text, template: "f(")
        time("replace all \(edits.count) (one undo step)") { editor.replace(edits) }
        time("undo it") { editor.undo() }
        let all = query.matches(in: editor.text, includeEmpty: false).prefix(FindBar.maxCursors)
            .map { Selection(anchor: $0.lowerBound, head: $0.upperBound) }
        time("cursor on all \(all.count) matches") { editor.setSelections(main: all[0], others: all) }
        time("type one char at every cursor") { editor.insertText("x") }
        time("undo it") { editor.undo() }
    }
}
