import AppKit

/// What Kite shows when nothing is open: recent folders and files as plain text, and the three
/// ways to start. ↑↓ and Return pick from the list; hovering and clicking work too.
@MainActor
final class StartWindow: NSWindowController, NSWindowDelegate {
    private static var current: StartWindow?

    static func show() {
        let start = current ?? StartWindow()
        current = start
        start.list.reload()
        start.fitHeight()
        start.showWindow(nil)
        start.window?.makeFirstResponder(start.list)
    }

    /// Closes the start window once a real window is up.
    static func dismiss() { current?.close() }

    private let list = RecentList()

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Kite"
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.backgroundColor = Chrome.background
        window.isMovableByWindowBackground = true
        super.init(window: window)
        window.delegate = self

        let root = ChromeView()
        window.contentView = root
        list.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(list)

        let buttons = NSStackView(views: [
            Chrome.textButton("open folder  ⇧⌘O", target: nil, action: #selector(AppDelegate.openFolderPanel(_:))),
            Chrome.textButton("open file  ⌘O", target: nil, action: #selector(NSDocumentController.openDocument(_:))),
            Chrome.textButton("new file  ⌘N", target: nil, action: #selector(NSDocumentController.newDocument(_:))),
        ])
        buttons.spacing = 28
        buttons.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: root.topAnchor, constant: 56),
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            list.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -40),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 54),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -32),
        ])
        list.onOpen = { [weak self] url in self?.open(url) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fitHeight() {
        guard let window else { return }
        let height = 56 + list.intrinsicContentSize.height + 96
        window.setContentSize(NSSize(width: 600, height: max(height, 260)))
        window.center()
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { MainActor.assumeIsolated { _ = NSApp.presentError(error) } }
        }
    }

    func windowWillClose(_ notification: Notification) { Self.current = nil }
}

/// The recent folders and files, drawn as text rows. The selected row gets a "›".
@MainActor
final class RecentList: NSView {
    private enum Row {
        case heading(String)
        case item(URL)
        case note(String)
    }

    var onOpen: ((URL) -> Void)?
    private var rows: [Row] = []
    private var selected: Int?

    private let rowHeight: CGFloat = 24
    private let headingGap: CGFloat = 14
    private let nameFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func reload() {
        let folders = RecentFolders.list.prefix(6)
        let files = NSDocumentController.shared.recentDocumentURLs
            .filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(6)
        rows = []
        if !folders.isEmpty { rows += [.heading("folders")] + folders.map(Row.item) }
        if !files.isEmpty { rows += [.heading("files")] + files.map(Row.item) }
        if rows.isEmpty { rows = [.note("nothing recent yet")] }
        selected = rows.firstIndex { if case .item = $0 { true } else { false } }
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.indices.map(top).last.map { $0 + rowHeight } ?? 0)
    }

    /// The y of a row: headings after the first get a gap above them.
    private func top(_ index: Int) -> CGFloat {
        var y: CGFloat = 0
        for i in 0..<index {
            y += rowHeight
            if case .heading = rows[i + 1] { y += headingGap }
        }
        return y
    }

    private func row(at point: NSPoint) -> Int? {
        rows.indices.first { point.y >= top($0) && point.y < top($0) + rowHeight }
    }

    override func draw(_ dirtyRect: NSRect) {
        let nameWidth = rows.compactMap { row -> CGFloat? in
            guard case .item(let url) = row else { return nil }
            return (url.lastPathComponent as NSString).size(withAttributes: [.font: nameFont]).width
        }.max() ?? 0

        for (i, row) in rows.enumerated() {
            let y = top(i)
            switch row {
            case .heading(let title), .note(let title):
                draw(title, x: 14, y: y + 4, font: Chrome.font, color: Chrome.faint)
            case .item(let url):
                let on = i == selected
                if on { draw("›", x: 0, y: y + 3, font: nameFont, color: Chrome.text) }
                draw(url.lastPathComponent, x: 14, y: y + 3, font: nameFont, color: on ? Chrome.bright : Chrome.secondary)
                let place = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                let x = 14 + min(nameWidth, 220) + 28
                let rect = NSRect(x: x, y: y + 4.5, width: max(bounds.width - x, 0), height: rowHeight)
                (place as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: attributes(Chrome.font, on ? Chrome.dim : Chrome.faint))
            }
        }
    }

    private func draw(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes(font, color))
    }

    private func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        return [.font: font, .foregroundColor: color, .paragraphStyle: style]
    }

    // MARK: Picking

    private func isItem(_ i: Int) -> Bool { if case .item = rows[i] { true } else { false } }

    private func move(_ step: Int) {
        guard var i = selected else { return }
        repeat { i += step } while rows.indices.contains(i) && !isItem(i)
        if rows.indices.contains(i) { selected = i; needsDisplay = true }
    }

    private func openSelected() {
        guard let selected, case .item(let url) = rows[selected] else { return }
        onOpen?(url)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)                 // ↓
        case 126: move(-1)                // ↑
        case 36, 76: openSelected()       // Return, Enter
        default: super.keyDown(with: event)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)), isItem(i), i != selected {
            selected = i
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)), isItem(i) {
            selected = i
            openSelected()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func resetCursorRects() {
        for i in rows.indices where isItem(i) {
            addCursorRect(NSRect(x: 0, y: top(i), width: bounds.width, height: rowHeight), cursor: .pointingHand)
        }
    }
}
