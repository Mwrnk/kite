import AppKit
import EditorCore
import Markdown
import Syntax

/// One open file inside a window: the gutter, the scrolling editor and the bots layer. Each tab
/// has its own pane, so switching tabs keeps every file's scroll position and cursors.
@MainActor
final class EditorPane {
    let editorView: EditorView
    let scrollView = NSScrollView()
    let gutter: LineNumberGutter
    let bots = BotsOverlay()
    /// The pane's whole area, ready to be placed in the window.
    let view = ChromeView()
    private(set) weak var document: TextDocument?
    /// The file shown when there's no document (offscreen rendering).
    var fileURL: URL?
    /// The backup file name this tab's unsaved text is kept in (stable, so saves overwrite it).
    var backupName: String?
    /// Where to scroll once the pane is first on screen (after a session restore).
    var pendingScrollY: CGFloat?
    /// Find results for this tab.
    let find: FindState
    /// Called after text or selection changes, once the pane has done its own bookkeeping.
    var onChange: ((_ textChanged: Bool) -> Void)?

    private var lastLineCount = 0
    /// The gutter and the scrolling editor, side by side.
    private let editorRow: NSStackView
    /// Made the first time the Markdown preview opens: the editor row on the left, the preview on the right.
    private var previewSplit: HairlineSplitView?
    private(set) var preview: MarkdownPreview?
    /// Bumped on every change, so a parse that finishes after a newer one is dropped.
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    /// False from a change until the preview shows it (dev tools wait on this).
    private(set) var isPreviewUpToDate = false

    init(editor: TextEditor, document: TextDocument?, language: Language?) {
        self.document = document
        editorView = EditorView(editor: editor)
        find = FindState(buffer: editor.buffer)
        editorView.findState = find
        gutter = LineNumberGutter(editorView: editorView)

        scrollView.documentView = editorView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let row = NSStackView(views: [gutter, scrollView])
        row.orientation = .horizontal
        row.spacing = 0
        row.alignment = .height
        row.translatesAutoresizingMaskIntoConstraints = false
        editorRow = row
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.addSubview(row)
        // Bots sit above the code; clicks pass through them.
        bots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bots)
        pin(row, to: view)
        pinBots()

        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.gutter.needsDisplay = true
                self?.updateBotFocus(.scrolled)
                self?.syncPreviewScroll()
            }
        }
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                               object: scrollView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.editorView.updateFrameSize() }
        }
        bots.isHidden = !BotsOverlay.isEnabled
        bots.requestFocus = { [weak self] in self?.updateBotFocus(.caretMoved) }
        NotificationCenter.default.addObserver(forName: BotsOverlay.didToggle, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.bots.isHidden = !BotsOverlay.isEnabled
                self?.updateBotFocus(.caretMoved)
            }
        }

        find.onChange = { [weak self] in self?.editorView.needsDisplay = true }
        setLanguage(language)
        editorView.onChange = { [weak self] textChanged in self?.editorDidChange(textChanged: textChanged) }
        editorView.onFontSizeChange = { [weak self] in
            guard let self, let preview = self.preview else { return }
            preview.fontSize = self.editorView.font.pointSize
            self.syncPreviewScroll()
        }
        lastLineCount = editor.buffer.lineCount
    }

    private func pin(_ child: NSView, to parent: NSView) {
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ])
    }

    /// The bots cover the editor's scroll view, and only that.
    private func pinBots() {
        NSLayoutConstraint.activate([
            bots.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            bots.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            bots.topAnchor.constraint(equalTo: scrollView.topAnchor),
            bots.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
    }

    // MARK: Markdown preview

    /// Files the preview is offered for.
    static func isMarkdown(_ url: URL?) -> Bool {
        guard let ext = url?.pathExtension.lowercased() else { return false }
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }

    var isPreviewShown: Bool { preview.map { !$0.isHidden } ?? false }

    /// Shows the preview beside the editor, or hides it.
    func togglePreview() {
        if isPreviewShown {
            preview?.isHidden = true
            previewSplit?.adjustSubviews()
            previewTask?.cancel()
            return
        }
        if previewSplit == nil { buildPreviewSplit() }
        preview?.isHidden = false
        previewSplit?.adjustSubviews()
        if let split = previewSplit {
            view.layoutSubtreeIfNeeded()
            split.setPosition(floor(split.bounds.width / 2), ofDividerAt: 0)
        }
        updatePreview(after: .zero)
    }

    /// Moves the editor row into a split with the preview beside it. Only done once per tab.
    private func buildPreviewSplit() {
        let split = HairlineSplitView()
        split.isVertical = true
        split.translatesAutoresizingMaskIntoConstraints = false
        let preview = MarkdownPreview(fileURL: document?.fileURL ?? fileURL)
        preview.fontSize = editorView.font.pointSize
        editorRow.removeFromSuperview()   // takes the bots' constraints with it
        view.addSubview(split, positioned: .below, relativeTo: bots)
        pin(split, to: view)
        split.addArrangedSubview(editorRow)
        split.addArrangedSubview(preview)
        pinBots()
        previewSplit = split
        self.preview = preview
    }

    /// True while a parse runs off the main thread. Only one runs at a time, so a long file
    /// being typed in doesn't pile up parses.
    private var isParsingPreview = false

    /// Parses the text after `delay` (a pause in typing), then shows it.
    private func updatePreview(after delay: Duration) {
        previewGeneration += 1
        isPreviewUpToDate = false
        previewTask?.cancel()   // only the wait; a parse already running carries on
        previewTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { return }
            }
            self?.parsePreview()
        }
    }

    private func parsePreview() {
        guard !isParsingPreview, isPreviewShown else { return }   // a running parse re-runs itself if needed
        isParsingPreview = true
        let generation = previewGeneration
        let text = editor.text
        Task { [weak self] in
            let parsed = await Task.detached(priority: .utility) { MarkdownDocument.parse(text) }.value
            guard let self else { return }
            self.isParsingPreview = false
            guard self.isPreviewShown, let preview = self.preview else { return }
            // Even if the text changed meanwhile, this is newer than what's shown.
            preview.fileURL = self.document?.fileURL ?? self.fileURL
            preview.show(parsed)
            self.syncPreviewScroll()
            if generation == self.previewGeneration {
                self.isPreviewUpToDate = true
            } else {
                self.parsePreview()
            }
        }
    }

    /// Puts the preview at the block the editor's top line is in.
    private func syncPreviewScroll() {
        guard isPreviewShown, let preview else { return }
        let y = scrollView.contentView.bounds.origin.y
        let line = editorView.line(atY: y)
        let top = editorView.lineTop(line)
        let height = max(editorView.lineTop(line + 1) - top, editorView.lineHeight)
        preview.scroll(toLine: line, fraction: min(max((y - top) / height, 0), 1))
    }

    var editor: TextEditor { editorView.editor }
    var language: Language? { editorView.syntax?.language }

    func setLanguage(_ language: Language?) {
        editor.settings.lineComment = language?.lineComment
        editorView.syntax = language.flatMap { SyntaxTree(language: $0, buffer: editor.buffer) }
    }

    private func editorDidChange(textChanged: Bool) {
        if textChanged {
            document?.editorTextDidChange()
            let count = editor.buffer.lineCount
            if String(count).count != String(lastLineCount).count { gutter.updateThickness() }
            lastLineCount = count
            if isPreviewShown { updatePreview(after: .milliseconds(150)) }
        }
        gutter.needsDisplay = true
        updateBotFocus(textChanged ? .edited : .caretMoved)
        onChange?(textChanged)
    }

    /// Tells the bots where the line being edited is, in the bots view's coordinates.
    func updateBotFocus(_ reason: BotsOverlay.FocusReason) {
        guard !bots.isHidden else { return }
        let buffer = editor.buffer
        let line = buffer.line(containing: editor.caret)
        let caret = editorView.caretRect(for: editor.caret)
        let textEnd = editorView.x(ofOffset: buffer.lineRange(line).upperBound)
        let lineRect = NSRect(x: editorView.textInsetX, y: editorView.lineTop(line),
                              width: max(textEnd - editorView.textInsetX, 0), height: editorView.lineHeight)
        bots.focus(lineRect: bots.convert(lineRect, from: editorView),
                   caret: bots.convert(NSPoint(x: caret.midX, y: caret.midY), from: editorView),
                   reason: reason)
    }

    /// The name shown in the tab.
    var title: String { (document?.fileURL ?? fileURL)?.lastPathComponent ?? "untitled" }

    /// An untitled file nobody has typed in.
    var isEmptyPlaceholder: Bool {
        guard let document else { return false }
        return document.fileURL == nil && !document.isDocumentEdited && editor.buffer.byteCount == 0
    }
}
