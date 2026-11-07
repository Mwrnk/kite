import AppKit
import EditorCore

/// ⌘P: type a few letters of a file name to jump to it. Fuzzy, so "edv" finds EditorView.swift.
@MainActor
final class QuickOpenPanel: NSPanel, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static var current: QuickOpenPanel?

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var heightConstraint: NSLayoutConstraint!
    private let project: Project?
    private var urls: [URL] = []
    private var candidates: [FuzzyCandidate] = []
    private var results: [(index: Int, result: FuzzyMatch.Result)] = []
    private let onPick: (URL) -> Void

    private static let rowHeight: CGFloat = 34
    private static let maxRows = 10

    /// Shows the panel over `window`, listing the project's files (or recent files without a project).
    static func show(over window: NSWindow, project: Project?, onPick: @escaping (URL) -> Void) {
        current?.dismiss()
        let panel = QuickOpenPanel(project: project, onPick: onPick)
        current = panel
        let width: CGFloat = min(600, window.frame.width - 40)
        let frame = window.frame
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.maxY - 90 - 400, width: width, height: 400), display: false)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.field)
        panel.refresh()
    }

    private init(project: Project?, onPick: @escaping (URL) -> Void) {
        self.project = project
        self.onPick = onPick
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false

        // The only raised surface in Kite: a flat panel with a hairline border.
        let background = RaisedView()
        contentView = background

        let inputFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = inputFont
        field.textColor = Chrome.text
        field.placeholderAttributedString = NSAttributedString(
            string: project.map { "file in \($0.name)" } ?? "recent file",
            attributes: [.font: inputFont, .foregroundColor: Chrome.faint])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("File name")
        let prompt = Chrome.label("›")
        prompt.font = inputFont
        let inputRow = NSStackView(views: [prompt, field])
        inputRow.spacing = 12

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.selectionHighlightStyle = .none   // the selected row gets a › instead of a bar
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        emptyLabel.textColor = Chrome.dim
        emptyLabel.font = Chrome.fileFont

        let topLine = ChromeView(), bottomLine = ChromeView()
        for line in [topLine, bottomLine] {
            line.fill = Chrome.raisedLine
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        let hints = Chrome.label("↵ open      esc close", color: Chrome.faint)
        let stack = NSStackView(views: [inputRow, topLine, scroll, emptyLabel, bottomLine, hints])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 10, right: 16)
        stack.setCustomSpacing(6, after: topLine)
        stack.setCustomSpacing(8, after: bottomLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        for v in [inputRow, scroll] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true }
        // Hairlines run the full width of the panel.
        for v in [topLine, bottomLine] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight * CGFloat(Self.maxRows))
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            heightConstraint,
        ])

        loadCandidates()
        if let project {
            NotificationCenter.default.addObserver(forName: Project.filesDidChange, object: project, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.loadCandidates(); self?.refresh() }
            }
        }
    }

    /// For `Kite --render … --quick-open QUERY`: the open panel, with `query` typed in.
    static func renderedForDevTools(query: String) -> NSView? {
        guard let panel = current else { return nil }
        panel.field.stringValue = query
        panel.refresh()
        return panel.contentView
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        dismiss()   // clicking anywhere else closes it
    }

    private func dismiss() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    // MARK: Candidates and results

    private func loadCandidates() {
        if let project {
            urls = project.files
            candidates = urls.map { FuzzyCandidate(project.relativePath($0)) }
        } else {
            urls = NSDocumentController.shared.recentDocumentURLs
            candidates = urls.map { FuzzyCandidate($0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
        }
    }

    private func refresh() {
        let query = field.stringValue
        if query.isEmpty {
            // Recently opened files first, then everything in path order.
            let recent = Set(NSDocumentController.shared.recentDocumentURLs.map(\.standardizedFileURL))
            let order = candidates.indices.sorted {
                let a = recent.contains(urls[$0].standardizedFileURL), b = recent.contains(urls[$1].standardizedFileURL)
                return a != b ? a : candidates[$0].text.localizedStandardCompare(candidates[$1].text) == .orderedAscending
            }
            results = order.prefix(50).map { ($0, FuzzyMatch.Result(score: 0, positions: [])) }
        } else {
            results = FuzzyMatch.rank(query, candidates)
        }
        table.reloadData()
        if !results.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }

        let indexing = project.map { !$0.isIndexed } ?? false
        emptyLabel.stringValue = indexing ? "Listing files…" : results.isEmpty ? "No matching files" : ""
        emptyLabel.isHidden = emptyLabel.stringValue.isEmpty
        heightConstraint.constant = Self.rowHeight * CGFloat(min(max(results.count, 1), Self.maxRows))
        resizeToFit()
    }

    private func resizeToFit() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        var frame = self.frame
        frame.origin.y += frame.height - height   // keep the top edge where it is
        frame.size.height = height
        setFrame(frame, display: true)
    }

    private func pick(_ row: Int) {
        guard results.indices.contains(row) else { return }
        let url = urls[results[row].index]
        dismiss()
        onPick(url)
    }

    @objc private func rowClicked(_ sender: Any?) { pick(table.clickedRow) }

    // MARK: Typing in the field

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): pick(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): dismiss()
        default: return false
        }
        return true
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let row = min(max(table.selectedRow + delta, 0), results.count - 1)
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Redraw the rows so the › follows the selection.
        table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<results.count), columnIndexes: [0])
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("result")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? ResultCell ?? ResultCell(identifier: id)
        let hit = results[row]
        cell.show(candidates[hit.index].text, matched: hit.result.positions, selected: row == tableView.selectedRow)
        return cell
    }
}

/// One result on one line: "› EditorView.swift" with the matched letters lit, the folder on the right.
private final class ResultCell: NSTableCellView {
    private let marker = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let folder = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        marker.font = Chrome.fileFont
        marker.textColor = Chrome.text
        folder.font = Chrome.font
        folder.textColor = Chrome.faint
        folder.alignment = .right
        for f in [marker, name, folder] {
            f.lineBreakMode = .byTruncatingMiddle
            f.translatesAutoresizingMaskIntoConstraints = false
            addSubview(f)
        }
        folder.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            marker.leadingAnchor.constraint(equalTo: leadingAnchor),
            marker.widthAnchor.constraint(equalToConstant: 18),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: marker.trailingAnchor),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            folder.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 16),
            folder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            folder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ path: String, matched: [Int], selected: Bool) {
        let bytes = Array(path.utf8)
        let nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
        let fileName = String(decoding: bytes[nameStart...], as: UTF8.self)
        let attributed = NSMutableAttributedString(string: fileName, attributes: [
            .font: Chrome.fileFont, .foregroundColor: selected ? Chrome.secondary : Chrome.dim,
        ])
        // Light up the letters the query matched (byte offsets → string ranges, for non-ASCII names too).
        for p in matched where p >= nameStart {
            let local = p - nameStart
            let utf8 = fileName.utf8
            guard local < utf8.count else { continue }
            let start = utf8.index(utf8.startIndex, offsetBy: local)
            guard let end = fileName[start...].indices.dropFirst().first ?? Optional(fileName.endIndex) else { continue }
            attributed.addAttributes([.foregroundColor: Chrome.bright], range: NSRange(start..<end, in: fileName))
        }
        if matched.isEmpty { attributed.addAttributes([.foregroundColor: selected ? Chrome.text : Chrome.secondary],
                                                      range: NSRange(location: 0, length: attributed.length)) }
        name.attributedStringValue = attributed
        marker.stringValue = selected ? "›" : ""
        folder.stringValue = nameStart > 0 ? String(decoding: bytes[..<(nameStart - 1)], as: UTF8.self) : ""
    }
}

/// The flat raised surface behind overlays: a slightly lighter fill and a hairline border.
private final class RaisedView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Chrome.raised.setFill()
        bounds.fill()
        Chrome.raisedLine.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
