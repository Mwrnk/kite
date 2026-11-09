import AppKit

/// The menu bar, built in code. Items send standard actions down the responder chain,
/// so the focused editor (or its window/document) handles them.
@MainActor
enum MainMenu {
    static func build(recentDelegate: NSMenuDelegate) -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "Kite")
        app.addItem(withTitle: "About Kite", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Kite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        item(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Kite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, "File")
        item(file, "New", #selector(NSDocumentController.newDocument(_:)), "n")
        item(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o")
        item(file, "Open Folder…", #selector(AppDelegate.openFolderPanel(_:)), "o", [.command, .shift])
        item(file, "Quick Open…", #selector(EditorWindowController.quickOpen(_:)), "p")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = recentDelegate
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        item(file, "Close Tab", #selector(EditorWindowController.closeTabAction(_:)), "w")
        item(file, "Close Window", #selector(NSWindow.performClose(_:)), "w", [.command, .shift])
        item(file, "Save", #selector(NSDocument.save(_:)), "s")
        item(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        item(file, "Save All", #selector(EditorWindowController.saveAllFiles(_:)), "s", [.command, .option])
        item(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)), "")

        let edit = submenu(main, "Edit")
        item(edit, "Undo", #selector(EditorView.undo(_:)), "z")
        item(edit, "Redo", #selector(EditorView.redo(_:)), "z", [.command, .shift])
        item(edit, "Undo Replace in Files", #selector(EditorWindowController.undoReplaceInFiles(_:)), "")
        edit.addItem(.separator())
        item(edit, "Cut", #selector(EditorView.cut(_:)), "x")
        item(edit, "Copy", #selector(EditorView.copy(_:)), "c")
        item(edit, "Paste", #selector(EditorView.paste(_:)), "v")
        item(edit, "Select All", #selector(NSResponder.selectAll(_:)), "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        item(find, "Find…", #selector(EditorWindowController.showFindBar(_:)), "f")
        item(find, "Find and Replace…", #selector(EditorWindowController.showFindAndReplace(_:)), "f", [.command, .option])
        item(find, "Find Next", #selector(EditorWindowController.findNext(_:)), "g")
        item(find, "Find Previous", #selector(EditorWindowController.findPrevious(_:)), "g", [.command, .shift])
        item(find, "Select All Matches", #selector(EditorWindowController.selectAllMatches(_:)), "g", [.command, .control])
        item(find, "Use Selection for Find", #selector(EditorWindowController.useSelectionForFind(_:)), "e")
        find.addItem(.separator())
        item(find, "Match Case", #selector(EditorWindowController.toggleFindCase(_:)), "c", [.command, .option])
        item(find, "Whole Word", #selector(EditorWindowController.toggleFindWord(_:)), "w", [.command, .option])
        item(find, "Regular Expression", #selector(EditorWindowController.toggleFindRegex(_:)), "r", [.command, .option])
        item(find, "In Selection", #selector(EditorWindowController.toggleFindInSelection(_:)), "l", [.command, .option])
        find.addItem(.separator())
        item(find, "Find in Project…", #selector(EditorWindowController.findInProject(_:)), "f", [.command, .shift])
        item(edit, "Go to Line…", #selector(EditorView.goToLine(_:)), "l")
        item(edit, "Go to Symbol…", #selector(EditorWindowController.goToSymbol(_:)), "t")
        item(edit, "Expand Selection", #selector(EditorView.expandSelection(_:)), arrow(NSRightArrowFunctionKey), [.control, .shift, .command])
        item(edit, "Shrink Selection", #selector(EditorView.shrinkSelection(_:)), arrow(NSLeftArrowFunctionKey), [.control, .shift, .command])
        edit.addItem(.separator())
        item(edit, "Toggle Comment", #selector(EditorView.toggleComment(_:)), "/")
        item(edit, "Indent", #selector(EditorView.indentLines(_:)), "]")
        item(edit, "Outdent", #selector(EditorView.outdentLines(_:)), "[")
        item(edit, "Move Line Up", #selector(EditorView.moveLineUp(_:)), arrow(NSUpArrowFunctionKey), [.option])
        item(edit, "Move Line Down", #selector(EditorView.moveLineDown(_:)), arrow(NSDownArrowFunctionKey), [.option])
        let lines = NSMenu(title: "Lines")
        edit.addItem(withTitle: "Lines", action: nil, keyEquivalent: "").submenu = lines
        item(lines, "Duplicate Line", #selector(EditorView.duplicateLines(_:)), "d", [.command, .shift])
        item(lines, "Delete Line", #selector(EditorView.deleteLines(_:)), "k", [.command, .shift])
        item(lines, "Join Lines", #selector(EditorView.joinLines(_:)), "j", [.control])
        item(lines, "Sort Lines", #selector(EditorView.sortLines(_:)), "")
        lines.addItem(.separator())
        item(lines, "Uppercase", #selector(EditorView.uppercase(_:)), "u", [.control, .shift])
        item(lines, "Lowercase", #selector(EditorView.lowercase(_:)), "l", [.control, .shift])
        item(lines, "Title Case", #selector(EditorView.titleCase(_:)), "")
        edit.addItem(.separator())
        item(edit, "Add Next Occurrence", #selector(EditorView.addNextOccurrence(_:)), "d")
        item(edit, "Split Selection into Lines", #selector(EditorView.splitSelectionIntoLines(_:)), "l", [.command, .shift])
        item(edit, "Add Cursor Above", #selector(EditorView.addCursorAbove(_:)), arrow(NSUpArrowFunctionKey), [.command, .option])
        item(edit, "Add Cursor Below", #selector(EditorView.addCursorBelow(_:)), arrow(NSDownArrowFunctionKey), [.command, .option])

        let view = submenu(main, "View")
        item(view, "Bigger Text", #selector(EditorView.zoomIn(_:)), "+")
        item(view, "Bigger Text", #selector(EditorView.zoomIn(_:)), "=").isHidden = true  // ⌘= without shift
        item(view, "Smaller Text", #selector(EditorView.zoomOut(_:)), "-")
        item(view, "Actual Size", #selector(EditorView.resetZoom(_:)), "0")
        view.addItem(.separator())
        item(view, "Show File List", #selector(EditorWindowController.toggleSidebar(_:)), "s", [.command, .control])
        item(view, "Rainbow Colors", #selector(EditorWindowController.toggleRainbowColors(_:)), "")
        view.addItem(.separator())
        item(view, "Next Tab", #selector(EditorWindowController.nextTab(_:)), "\t", [.control])
        item(view, "Previous Tab", #selector(EditorWindowController.previousTab(_:)), "\t", [.control, .shift])
        view.addItem(.separator())
        item(view, "Word Wrap", #selector(EditorView.toggleWordWrap(_:)), "z", [.option])
        item(view, "Show Bots", #selector(EditorWindowController.toggleBots(_:)), "b", [.command, .shift])
        item(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        let window = submenu(main, "Window")
        item(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "Zoom", #selector(NSWindow.performZoom(_:)), "")
        window.addItem(.separator())
        item(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ parent: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        parent.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }

    @discardableResult
    private static func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func arrow(_ key: Int) -> String { String(Character(UnicodeScalar(UInt16(key))!)) }
}
