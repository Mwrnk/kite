import AppKit
import EditorCore
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
    /// Called after text or selection changes, once the pane has done its own bookkeeping.
    var onChange: ((_ textChanged: Bool) -> Void)?

    private var lastLineCount = 0

    init(editor: TextEditor, document: TextDocument?, language: Language?) {
        self.document = document
        editorView = EditorView(editor: editor)
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
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.addSubview(row)
        // Bots sit above the code; clicks pass through them.
        bots.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bots)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.topAnchor.constraint(equalTo: view.topAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bots.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            bots.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            bots.topAnchor.constraint(equalTo: scrollView.topAnchor),
            bots.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])

        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.gutter.needsDisplay = true
                self?.updateBotFocus(.scrolled)
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

        setLanguage(language)
        editorView.onChange = { [weak self] textChanged in self?.editorDidChange(textChanged: textChanged) }
        lastLineCount = editor.buffer.lineCount
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
