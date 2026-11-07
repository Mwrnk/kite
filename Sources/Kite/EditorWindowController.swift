import AppKit
import EditorCore
import Syntax

/// A Kite window: the project's file list on the left, text tabs on top, the open file's pane,
/// and a one-line status line at the bottom. Each tab is a document with its own pane.
///
/// macOS's document system expects one window per document, so the window is attached to
/// whichever document is in the active tab; the others wait detached until they're selected.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    private(set) var panes: [EditorPane] = []
    private var activeIndex = -1
    private var activePane: EditorPane? { panes.indices.contains(activeIndex) ? panes[activeIndex] : nil }
    /// The editor in the active tab.
    var editorView: EditorView { activePane!.editorView }

    /// The folder this window belongs to, if any.
    private(set) var project: Project?
    private let root = ChromeRootView()
    private let split = HairlineSplitView()
    private var sidebar: ProjectSidebar?
    private let mainColumn = NSStackView()
    private let tabBar = TabBar()
    private let paneHost = ChromeView()
    private let emptyLabel = Chrome.label("⌘P open a file      ⌘N new file")
    private let statusBar = ChromeView()
    private let statusLeft = Chrome.label()
    private let statusRight = Chrome.label()
    private var closingConfirmed = false

    // Find bar.
    private let findBar = ChromeView()
    private let findField = NSTextField()
    private let findCount = Chrome.label()
    private let caseButton = Chrome.textButton("Aa", target: nil, action: nil)

    /// Builds a window showing `document`. With no document (offscreen rendering), shows `editor`.
    init(document: TextDocument?, editor: TextEditor? = nil, language: Language? = nil, fileURL: URL? = nil) {
        project = document?.fileURL.flatMap { Project.containing($0) } ?? Project.pendingForNewWindow

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.tabbingMode = .disallowed          // Kite draws its own tabs
        window.isRestorable = false               // SessionStore restores windows itself
        window.backgroundColor = Chrome.background
        window.minSize = NSSize(width: 480, height: 280)
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        buildLayout(in: window)
        setWindowButtonsVisible(false)
        if let project { showSidebar(for: project) }

        let pane = EditorPane(editor: editor ?? document?.editor ?? TextEditor(), document: document,
                              language: language ?? document?.language)
        pane.fileURL = fileURL
        panes = [pane]
        activate(0)
        if document != nil { window.setFrameAutosaveName("KiteEditorWindow") }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Finding windows for documents

    static var all: [EditorWindowController] {
        NSApp.orderedWindows.compactMap { $0.windowController as? EditorWindowController }
    }

    /// The window already showing `document` in one of its tabs.
    static func controller(containing document: NSDocument) -> EditorWindowController? {
        all.first { $0.panes.contains { $0.document === document } }
    }

    /// Where a newly opened document should go: its project's window, else the front window.
    /// Nil means it gets a window of its own.
    static func windowForNewDocument(_ document: TextDocument) -> EditorWindowController? {
        if Project.pendingForNewWindow != nil { return nil }
        if let project = Project.containing(document.fileURL) {
            return all.first { $0.project === project } ?? all.first { $0.project == nil && $0.window?.isVisible == true }
        }
        return all.first { $0.window?.isVisible == true }
    }

    // MARK: Layout

    private func buildLayout(in window: NSWindow) {
        // Tabs, find bar and the open file, stacked.
        tabBar.onSelect = { [weak self] i in self?.activate(i) }
        tabBar.onClose = { [weak self] i in self?.closeTab(i) }
        buildFindBar()
        mainColumn.orientation = .vertical
        mainColumn.spacing = 0
        mainColumn.alignment = .leading
        for v in [tabBar, findBar, paneHost] as [NSView] {
            mainColumn.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: mainColumn.widthAnchor).isActive = true
        }
        tabBar.heightAnchor.constraint(equalToConstant: Chrome.barHeight).isActive = true
        paneHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        paneHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        paneHost.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: paneHost.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: paneHost.centerYAnchor, constant: -30),
        ])

        split.isVertical = true
        split.addArrangedSubview(mainColumn)

        // Status line across the bottom: where you are on the left, what's under the cursor on the right.
        statusBar.hairlines = [.minY]
        statusRight.alignment = .right
        statusLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [statusLeft, statusRight] {
            label.translatesAutoresizingMaskIntoConstraints = false
            statusBar.addSubview(label)
        }

        for v in [split, statusBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Chrome.statusHeight),
            statusLeft.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 18),
            statusLeft.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusRight.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -18),
            statusRight.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusRight.leadingAnchor.constraint(greaterThanOrEqualTo: statusLeft.trailingAnchor, constant: 24),
        ])
        root.onTopHover = { [weak self] inside in self?.setWindowButtonsVisible(inside) }
        window.contentView = root
    }

    private func buildFindBar() {
        findBar.hairlines = [.maxY]
        findField.isBordered = false
        findField.drawsBackground = false
        findField.focusRingType = .none
        findField.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        findField.textColor = Chrome.text
        findField.placeholderAttributedString = NSAttributedString(string: "text to find", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: Chrome.faint,
        ])
        findField.delegate = self
        findField.cell?.usesSingleLineMode = true
        caseButton.target = self
        caseButton.action = #selector(toggleCase(_:))
        caseButton.toolTip = "Match case"
        let previous = Chrome.textButton("↑", target: self, action: #selector(findPrevious(_:)))
        let next = Chrome.textButton("↓", target: self, action: #selector(findNext(_:)))
        previous.toolTip = "Previous match (⇧⌘G)"
        next.toolTip = "Next match (⌘G)"
        let label = Chrome.label("find")
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let row = NSStackView(views: [label, findField, findCount, caseButton, previous, next])
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        row.translatesAutoresizingMaskIntoConstraints = false
        findField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        findBar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: findBar.trailingAnchor),
            row.centerYAnchor.constraint(equalTo: findBar.centerYAnchor),
            findBar.heightAnchor.constraint(equalToConstant: 36),
        ])
        findBar.isHidden = true
    }

    private func setWindowButtonsVisible(_ visible: Bool) {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(kind)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Room on the left of the tabs for the window buttons when there's no file list beside them.
    private func updateTabInset() {
        tabBar.leadingInset = (sidebar.map { !$0.isHidden } ?? false) ? 8 : 84
    }

    // MARK: Tabs

    /// Shows `document` in a new tab (or its existing one).
    func addTab(for document: TextDocument) {
        if let existing = panes.firstIndex(where: { $0.document === document }) { activate(existing); return }
        let pane = EditorPane(editor: document.editor, document: document, language: document.language)
        let at = panes.isEmpty ? 0 : activeIndex + 1
        panes.insert(pane, at: at)
        if activeIndex >= at { activeIndex += 1 }
        activate(at)
        // An empty untitled tab is replaced by the first real file opened next to it.
        if document.fileURL != nil, let placeholder = panes.firstIndex(where: { $0 !== pane && $0.isEmptyPlaceholder }) {
            closeTab(placeholder)
        }
    }

    /// Brings the tab showing `document` forward.
    func activate(document: NSDocument) {
        if let i = panes.firstIndex(where: { $0.document === document }) { activate(i) }
    }

    func activate(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        let old = activePane
        let pane = panes[index]
        if let old, old !== pane {
            old.document?.removeWindowController(self)
            old.view.removeFromSuperview()
            old.onChange = nil
        }
        activeIndex = index
        if pane.view.superview !== paneHost {
            pane.view.translatesAutoresizingMaskIntoConstraints = false
            paneHost.addSubview(pane.view)
            NSLayoutConstraint.activate([
                pane.view.leadingAnchor.constraint(equalTo: paneHost.leadingAnchor),
                pane.view.trailingAnchor.constraint(equalTo: paneHost.trailingAnchor),
                pane.view.topAnchor.constraint(equalTo: paneHost.topAnchor),
                pane.view.bottomAnchor.constraint(equalTo: paneHost.bottomAnchor),
            ])
        }
        if let y = pane.pendingScrollY {
            pane.pendingScrollY = nil
            paneHost.layoutSubtreeIfNeeded()
            pane.editorView.updateFrameSize()
            pane.editorView.scroll(NSPoint(x: 0, y: y))
        }
        // The window belongs to the active tab's document (saving, the unsaved state, sheets).
        if let doc = pane.document, !doc.windowControllers.contains(self) { doc.addWindowController(self) }
        pane.onChange = { [weak self] textChanged in self?.paneDidChange(textChanged: textChanged) }
        pane.editorView.findQuery = findBar.isHidden ? "" : findField.stringValue
        emptyLabel.isHidden = true
        window?.makeFirstResponder(pane.editorView)
        sidebar?.reveal(pane.document?.fileURL)
        refreshTabs()
        updateStatus()
        SessionStore.scheduleSave()
    }

    private func paneDidChange(textChanged: Bool) {
        if textChanged {
            refreshTabs()
            if !findBar.isHidden { updateFindCount() }
            SessionStore.scheduleSave()
        }
        updateStatus()
    }

    func refreshTabs() {
        // Files with the same name get their folder added, so the tabs can be told apart.
        let names = panes.map(\.title)
        tabBar.items = panes.enumerated().map { i, pane in
            var title = names[i]
            if names.filter({ $0 == title }).count > 1, let parent = pane.document?.fileURL?.deletingLastPathComponent().lastPathComponent {
                title = parent + "/" + title
            }
            return TabBar.Item(title: title, isActive: i == activeIndex, isDirty: pane.document?.isDocumentEdited ?? false)
        }
    }

    /// Closes a tab, asking to save first if it has unsaved changes.
    func closeTab(_ index: Int) {
        guard panes.indices.contains(index) else { return }
        guard let doc = panes[index].document else { removePane(index); return }
        if doc.isDocumentEdited {
            activate(index)   // the save prompt appears over this window, for this file
            doc.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
            return
        }
        finishClosing(doc)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if shouldClose, let doc = document as? TextDocument { finishClosing(doc) }
    }

    private func finishClosing(_ doc: TextDocument) {
        guard let i = panes.firstIndex(where: { $0.document === doc }) else { return }
        doc.removeWindowController(self)
        removePane(i)
        doc.close()
    }

    private func removePane(_ index: Int) {
        let pane = panes.remove(at: index)
        pane.view.removeFromSuperview()
        pane.onChange = nil
        let wasActive = index == activeIndex
        if index < activeIndex || (wasActive && activeIndex == panes.count) { activeIndex -= 1 }
        if panes.isEmpty {
            activeIndex = -1
            if project == nil { closingConfirmed = true; window?.close(); return }
            emptyLabel.isHidden = false
            window?.makeFirstResponder(nil)
            refreshTabs()
            updateStatus()
            return
        }
        if wasActive {
            let next = activeIndex
            activeIndex = -1
            activate(max(next, 0))
        } else {
            refreshTabs()
        }
    }

    @objc func closeTabAction(_ sender: Any?) {
        if activePane == nil { window?.performClose(sender) } else { closeTab(activeIndex) }
    }

    @objc func nextTab(_ sender: Any?) {
        guard panes.count > 1 else { return }
        activate((activeIndex + 1) % panes.count)
    }

    @objc func previousTab(_ sender: Any?) {
        guard panes.count > 1 else { return }
        activate((activeIndex - 1 + panes.count) % panes.count)
    }

    // MARK: Closing the window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closingConfirmed { closeAllDocuments(); return true }
        let dirty = panes.compactMap(\.document).filter(\.isDocumentEdited)
        guard !dirty.isEmpty else { closeAllDocuments(); return true }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "Save changes to \(dirty[0].displayName ?? "this file")?"
            : "\(dirty.count) files have unsaved changes."
        alert.informativeText = "Your changes will be lost if you don't save them."
        let canSaveAll = dirty.allSatisfy { $0.fileURL != nil }
        if canSaveAll { alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All") }
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                let save = canSaveAll && response == .alertFirstButtonReturn
                let discard = canSaveAll ? response == .alertSecondButtonReturn : response == .alertFirstButtonReturn
                if save {
                    self.saveAll(dirty) { self.closingConfirmed = true; self.window?.close() }
                } else if discard {
                    self.closingConfirmed = true
                    self.window?.close()
                }
            }
        }
        return false
    }

    private func saveAll(_ documents: [TextDocument], then done: @escaping () -> Void) {
        var remaining = documents
        func next() {
            guard let doc = remaining.popLast(), let url = doc.fileURL else { done(); return }
            doc.save(to: url, ofType: doc.fileType ?? "Text", for: .saveOperation) { error in
                MainActor.assumeIsolated {
                    if let error { _ = NSApp.presentError(error) } else { next() }
                }
            }
        }
        next()
    }

    private func closeAllDocuments() {
        for pane in panes {
            guard let doc = pane.document else { continue }
            doc.removeWindowController(self)
            doc.close()
        }
        panes.removeAll()
        activeIndex = -1
    }

    // MARK: Session

    /// This window as the session stores it. Unsaved text is written to a backup file per tab.
    func sessionState(backupsIn directory: URL, used: inout Set<String>) -> SessionStore.WindowState? {
        guard let window, window.isVisible else { return nil }
        var tabs: [SessionStore.TabState] = []
        var active = 0
        for (i, pane) in panes.enumerated() {
            guard let doc = pane.document else { continue }
            let editor = pane.editor
            var backup: String?
            if doc.isDocumentEdited || (doc.fileURL == nil && editor.buffer.byteCount > 0) {
                let name = pane.backupName ?? UUID().uuidString + ".txt"
                pane.backupName = name
                try? editor.text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                used.insert(name)
                backup = name
            }
            if doc.fileURL == nil && backup == nil { continue }   // an empty untitled tab: nothing to keep
            if i == activeIndex { active = tabs.count }
            let extras = editor.extraSelections.map { [$0.anchor, $0.head] }
            tabs.append(SessionStore.TabState(
                path: doc.fileURL?.path, anchor: editor.selection.anchor, head: editor.selection.head,
                extra: extras.isEmpty ? nil : extras,
                // A tab not shown since the restore hasn't scrolled yet: keep where it was.
                scrollY: Double(pane.pendingScrollY ?? pane.scrollView.contentView.bounds.origin.y), backup: backup))
        }
        if tabs.isEmpty && project == nil { return nil }
        return SessionStore.WindowState(project: project?.root.path, frame: NSStringFromRect(window.frame),
                                        fileListHidden: sidebar?.isHidden ?? false, active: active, tabs: tabs)
    }

    /// A new untitled document, of the same type ⌘N makes.
    private static func makeUntitled() -> TextDocument? {
        let controller = NSDocumentController.shared
        guard let type = controller.defaultType else { return nil }
        return (try? controller.makeUntitledDocument(ofType: type)) as? TextDocument
    }

    /// Rebuilds a window from the session. Files that no longer exist are skipped, unless they had
    /// unsaved text, which then opens as an untitled file. Returns false if nothing could be shown.
    static func restore(_ state: SessionStore.WindowState, backupsIn directory: URL) -> Bool {
        let fm = FileManager.default
        let project = state.project.flatMap { fm.fileExists(atPath: $0) ? Project.open(URL(fileURLWithPath: $0)) : nil }
        var restored: [(doc: TextDocument, tab: SessionStore.TabState, backup: String?)] = []
        for tab in state.tabs {
            let backupText = tab.backup.flatMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
            var doc: TextDocument?
            if let path = tab.path, fm.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                if NSDocumentController.shared.document(for: url) != nil { continue }   // already open
                doc = try? TextDocument(contentsOf: url, ofType: "Text")
            } else if backupText != nil {
                doc = makeUntitled()
            }
            guard let doc else { continue }
            if let backupText {
                // One undoable step on top of the file as it is on disk, so ⌘Z gets back to it.
                doc.editor.setSelection(Selection(anchor: 0, head: doc.editor.buffer.byteCount))
                doc.editor.replaceSelection(with: backupText)
            }
            restored.append((doc, tab, tab.backup))
        }
        guard !restored.isEmpty || project != nil else { return false }

        // A window opened at launch (a file from Finder or the command line) that belongs to this
        // folder takes the tabs in, and its file stays in front. Otherwise the first document makes
        // the window and the rest join it as tabs.
        let joined = project.flatMap { p in all.first { $0.adopt(p) } }
        let front = joined?.activePane
        let controller: EditorWindowController
        Project.pendingForNewWindow = project
        if let joined {
            controller = joined
            if let first = restored.first?.doc {
                NSDocumentController.shared.addDocument(first)
                controller.addTab(for: first)
            }
        } else if let first = restored.first?.doc {
            NSDocumentController.shared.addDocument(first)
            controller = EditorWindowController(document: first)
            first.addWindowController(controller)
        } else {
            guard let placeholder = makeUntitled() else {
                Project.pendingForNewWindow = nil
                return false
            }
            NSDocumentController.shared.addDocument(placeholder)
            controller = EditorWindowController(document: placeholder)
            placeholder.addWindowController(controller)
        }
        Project.pendingForNewWindow = nil
        for item in restored.dropFirst() {
            NSDocumentController.shared.addDocument(item.doc)
            controller.addTab(for: item.doc)
        }

        if joined == nil, let window = controller.window {
            window.setFrame(NSRectFromString(state.frame), display: false)
        }
        if joined == nil, state.fileListHidden, let sidebar = controller.sidebar, !sidebar.isHidden { controller.toggleSidebar(nil) }
        for item in restored {
            guard let pane = controller.panes.first(where: { $0.document === item.doc }) else { continue }
            let count = item.doc.editor.buffer.byteCount
            // Extra cursors first, then the main one, since the last cursor added becomes the main one.
            let main = Selection(anchor: min(item.tab.anchor, count), head: min(item.tab.head, count))
            let extras = (item.tab.extra ?? []).filter { $0.count == 2 }
                .map { Selection(anchor: min($0[0], count), head: min($0[1], count)) }
            item.doc.editor.setSelection(extras.first ?? main)
            for extra in extras.dropFirst() { item.doc.editor.addSelection(extra) }
            if !extras.isEmpty { item.doc.editor.addSelection(main) }
            item.doc.editorTextDidChange()   // shows the unsaved dot for restored edits
            pane.backupName = item.backup
            pane.pendingScrollY = CGFloat(item.tab.scrollY)
        }
        controller.refreshTabs()
        let active = front.flatMap { f in controller.panes.firstIndex { $0 === f } }
            ?? min(max(state.active, 0), max(controller.panes.count - 1, 0))
        controller.activate(active)
        controller.showWindow(nil)
        return true
    }

    // MARK: Status line

    private func updateStatus() {
        statusLeft.stringValue = locationText()
        guard let pane = activePane else { statusRight.stringValue = ""; return }
        let e = pane.editor
        let line = e.buffer.line(containing: e.caret)
        var parts = ["Ln \(line + 1), Col \(e.displayColumn(of: e.caret) + 1)"]
        if e.hasMultipleCursors {
            parts[0] = "\(e.allSelections.count) cursors"
        } else if !e.selection.isEmpty {
            parts[0] += " (\(e.selectedText.count) selected)"
        }
        parts.append(e.settings.insertSpaces ? "spaces \(e.settings.tabWidth)" : "tabs")
        if let format = pane.document?.format {
            parts.append(format.encodingLabel)
            parts.append(format.lineEnding.label)
        }
        parts.append(pane.language?.displayName ?? "Plain Text")
        statusRight.stringValue = parts.joined(separator: "    ")
    }

    /// "runner · main" for a project; the file's folder otherwise.
    private func locationText() -> String {
        if let project {
            let branch = Self.gitBranch(at: project.root)
            return branch.map { "\(project.name) · \($0)" } ?? project.name
        }
        guard let url = activePane?.document?.fileURL else { return "" }
        return url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// The checked-out branch, read straight from .git/HEAD (no git process).
    private static func gitBranch(at root: URL) -> String? {
        guard let head = try? String(contentsOf: root.appendingPathComponent(".git/HEAD"), encoding: .utf8) else { return nil }
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") { return String(line.dropFirst("ref: refs/heads/".count)) }
        return String(line.prefix(7))   // detached: short commit id
    }

    func documentDidSave(_ document: TextDocument) {
        // Save As may have changed the file name and its language.
        if let pane = panes.first(where: { $0.document === document }), pane.language != document.language {
            pane.setLanguage(document.language)
        }
        refreshTabs()
        updateStatus()
    }

    // MARK: Window

    func windowDidBecomeKey(_ notification: Notification) {
        activePane?.editorView.needsDisplay = true
        sidebar?.reveal(activePane?.document?.fileURL)
        updateStatus()
    }

    func windowDidResignKey(_ notification: Notification) { activePane?.editorView.needsDisplay = true }

    func windowWillClose(_ notification: Notification) { SessionStore.scheduleSave() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        StartWindow.dismiss()
    }

    /// Redraws the line numbers (after font size changes).
    func refreshGutter() {
        activePane?.gutter.updateThickness()
        activePane?.gutter.needsDisplay = true
    }

    // MARK: Project

    func revealInSidebar(_ url: URL?) { sidebar?.reveal(url) }

    private func showSidebar(for project: Project) {
        guard sidebar == nil else { return }
        let sidebar = ProjectSidebar(project: project)
        sidebar.onOpen = { [weak self] url, match in self?.openFromProject(url, select: match) }
        split.insertArrangedSubview(sidebar, at: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 1)
        split.setPosition(232, ofDividerAt: 0)
        split.autosaveName = "KiteFileList"
        self.sidebar = sidebar
        updateTabInset()
    }

    /// A folder was just opened: if a tab here holds a file inside it, this window joins that project.
    @discardableResult
    func adopt(_ project: Project) -> Bool {
        if self.project === project { return true }
        guard self.project == nil, panes.contains(where: { Project.containing($0.document?.fileURL) === project }) else { return false }
        self.project = project
        showSidebar(for: project)
        sidebar?.reveal(activePane?.document?.fileURL)
        updateStatus()
        return true
    }

    @objc func findInProject(_ sender: Any?) {
        guard let sidebar else { return }
        if sidebar.isHidden { toggleSidebar(nil) }
        let selected = activePane?.editor.selectedText ?? ""
        sidebar.showSearch(with: selected.isEmpty ? nil : selected)
    }

    func searchProjectForDevTools(_ query: String) { sidebar?.showSearch(with: query) }

    @objc func quickOpen(_ sender: Any?) {
        guard let window else { return }
        QuickOpenPanel.show(over: window, project: project) { [weak self] url in self?.openFromProject(url) }
    }

    @objc func toggleSidebar(_ sender: Any?) {
        guard let sidebar else { return }
        sidebar.isHidden.toggle()
        split.adjustSubviews()
        updateTabInset()
    }

    /// Opens a file in a tab here, selecting `match` if given.
    private func openFromProject(_ url: URL, select match: TextSearch.Match? = nil) {
        if Self.looksBinary(url) { NSWorkspace.shared.open(url); return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { opened, _, error in
            MainActor.assumeIsolated {
                if let error { _ = NSApp.presentError(error); return }
                if let match, let editor = (opened as? TextDocument)?.editor {
                    let start = editor.buffer.offset(of: TextPoint(row: match.line, column: match.column))
                    editor.setSelection(Selection(anchor: start, head: min(start + match.length, editor.buffer.byteCount)))
                }
            }
        }
    }

    /// Images, archives and other non-text files open in their usual app instead.
    private static func looksBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return head.contains(0)
    }

    // MARK: Menu toggles

    @objc func toggleBots(_ sender: Any?) { BotsOverlay.isEnabled.toggle() }

    @objc func toggleRainbowColors(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "rainbowColors"), forKey: "rainbowColors")
        for controller in Self.all {
            for pane in controller.panes {
                pane.editorView.viewDidChangeEffectiveAppearance()
                pane.gutter.needsDisplay = true
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findInProject(_:)): return sidebar != nil
        case #selector(toggleSidebar(_:)):
            item.state = sidebar.map { $0.isHidden ? .off : .on } ?? .off
            return sidebar != nil
        case #selector(toggleBots(_:)): item.state = BotsOverlay.isEnabled ? .on : .off
        case #selector(toggleRainbowColors(_:)): item.state = UserDefaults.standard.bool(forKey: "rainbowColors") ? .on : .off
        case #selector(nextTab(_:)), #selector(previousTab(_:)): return panes.count > 1
        case #selector(showFindBar(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(useSelectionForFind(_:)):
            return activePane != nil
        default: break
        }
        return true
    }

    // MARK: Find

    var isFindBarVisible: Bool { !findBar.isHidden }

    @objc func showFindBar(_ sender: Any?) {
        guard let pane = activePane else { return }
        findBar.isHidden = false
        if !pane.editor.selection.isEmpty, !pane.editor.selectedText.contains("\n") {
            findField.stringValue = pane.editor.selectedText
        }
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        applyQuery()
    }

    func hideFindBar() {
        findBar.isHidden = true
        activePane?.editorView.findQuery = ""
        if let pane = activePane { window?.makeFirstResponder(pane.editorView) }
    }

    @objc private func toggleCase(_ sender: Any?) {
        caseButton.isOn.toggle()
        activePane?.editorView.findCaseSensitive = caseButton.isOn
        applyQuery()
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let pane = activePane else { return }
        let text = pane.editor.selectedText
        guard !text.isEmpty else { return }
        findField.stringValue = text
        pane.editorView.findQuery = isFindBarVisible ? text : ""
    }

    private func applyQuery() {
        activePane?.editorView.findQuery = findField.stringValue
        updateFindCount()
    }

    private func updateFindCount() {
        let query = findField.stringValue
        guard !query.isEmpty, let pane = activePane else { findCount.stringValue = ""; return }
        let buffer = pane.editor.buffer
        // Counting is a full scan; skip it for very large files.
        guard buffer.byteCount < 4_000_000 else { findCount.stringValue = ""; return }
        let n = pane.editor.matches(of: query, in: 0..<buffer.byteCount, caseSensitive: caseButton.isOn).count
        findCount.stringValue = n == 1 ? "1 match" : "\(n) matches"
    }

    func controlTextDidChange(_ obj: Notification) {
        applyQuery()
        // Jump to the first match at or after the selection start as you type.
        guard let e = activePane?.editor else { return }
        if let r = e.find(findField.stringValue, from: e.selection.range.lowerBound, caseSensitive: caseButton.isOn) {
            e.setSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
        }
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

    private func find(backwards: Bool) {
        guard let pane = activePane else { return }
        let query = findField.stringValue
        guard !query.isEmpty else { showFindBar(nil); return }
        pane.editorView.findQuery = isFindBarVisible ? query : ""
        let e = pane.editor
        let from = backwards ? e.selection.range.lowerBound : e.selection.range.upperBound
        guard let r = e.find(query, from: from, backwards: backwards, caseSensitive: caseButton.isOn) else {
            NSSound.beep(); return
        }
        e.setSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)): hideFindBar()
        case #selector(NSResponder.insertNewline(_:)):
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? findPrevious(nil) : findNext(nil)
        default: return false
        }
        return true
    }
}

/// The window's background view. Shows the window buttons while the pointer is near the top edge.
final class ChromeRootView: ChromeView {
    var onTopHover: ((Bool) -> Void)?
    private var nearTop = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let near = convert(event.locationInWindow, from: nil).y < Chrome.barHeight + 4
        if near != nearTop { nearTop = near; onTopHover?(near) }
    }

    override func mouseExited(with event: NSEvent) {
        if nearTop { nearTop = false; onTopHover?(false) }
    }
}
