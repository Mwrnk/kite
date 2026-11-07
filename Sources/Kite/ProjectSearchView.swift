import AppKit
import EditorCore

/// Search across every file in the project (⌘⇧F). Results are grouped by file; clicking one
/// opens the file with the match selected. Searching runs in the background as you type.
@MainActor
final class ProjectSearchView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    /// Called with a file and the match to select in it.
    var onOpen: ((URL, TextSearch.Match) -> Void)?

    private let project: Project
    private let field = NSTextField()
    private let caseButton = Chrome.textButton("Aa", target: nil, action: nil)
    private let status = Chrome.label()
    private let outline = QuietOutlineView()
    private var results: [FileResult] = []
    private var generation = 0
    private var pending: DispatchWorkItem?

    nonisolated static let maxMatches = 2000

    final class FileResult {
        let url: URL
        let path: String
        var matches: [MatchRow] = []
        init(url: URL, path: String) { self.url = url; self.path = path }
    }

    final class MatchRow {
        let match: TextSearch.Match
        unowned let file: FileResult
        init(match: TextSearch.Match, file: FileResult) { self.match = match; self.file = file }
    }

    init(project: Project) {
        self.project = project
        super.init(frame: .zero)

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Chrome.fileFont
        field.textColor = Chrome.text
        field.placeholderAttributedString = NSAttributedString(string: "search in \(project.name)", attributes: [
            .font: Chrome.fileFont, .foregroundColor: Chrome.faint,
        ])
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        caseButton.toolTip = "Match case"
        caseButton.target = self
        caseButton.action = #selector(toggleCase(_:))
        status.lineBreakMode = .byTruncatingTail

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 12
        outline.usesAutomaticRowHeights = true
        outline.rowSizeStyle = .custom   // otherwise the source-list style replaces our fonts
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.setAccessibilityLabel("Search results")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let row = NSStackView(views: [field, caseButton])
        row.spacing = 10
        let stack = NSStackView(views: [row, status, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [row, status] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Puts the cursor in the search field, optionally filling it in (e.g. with the selected text).
    func focus(with text: String? = nil) {
        if let text, !text.isEmpty, !text.contains("\n") {
            field.stringValue = text
            queryChanged(nil)
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let first = results.first?.matches.first {
            onOpen?(first.file.url, first.match)   // Return opens the first result
            return true
        }
        return false
    }

    // MARK: Running a search

    func controlTextDidChange(_ obj: Notification) { queryChanged(nil) }

    @objc private func toggleCase(_ sender: Any?) {
        caseButton.isOn.toggle()
        queryChanged(nil)
    }

    @objc private func queryChanged(_ sender: Any?) {
        // Wait for a short pause in typing before searching.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startSearch() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func startSearch() {
        generation += 1
        let myGeneration = generation
        results = []
        outline.reloadData()
        let query = field.stringValue
        guard !query.isEmpty else { status.stringValue = ""; return }
        status.stringValue = "Searching…"

        let caseSensitive = caseButton.isOn
        let files = project.files
        let paths = files.map { project.relativePath($0) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var batch: [(URL, String, [TextSearch.Match])] = []
            var total = 0
            var lastFlush = Date()
            for (url, path) in zip(files, paths) {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= TextSearch.maxFileSize else { continue }
                let found = TextSearch.matches(of: query, in: data, caseSensitive: caseSensitive,
                                               limit: min(200, Self.maxMatches - total))
                if !found.isEmpty { batch.append((url, path, found)); total += found.count }
                // Hand results over in batches, so the list fills in as the search goes.
                if !batch.isEmpty && (Date().timeIntervalSince(lastFlush) > 0.1 || total >= Self.maxMatches) {
                    let chunk = batch
                    batch = []
                    lastFlush = Date()
                    let stillCurrent = await MainActor.run { self?.append(chunk, generation: myGeneration) ?? false }
                    if !stillCurrent { return }
                }
                if total >= Self.maxMatches { break }
            }
            let chunk = batch
            await MainActor.run { self?.finish(chunk, generation: myGeneration, capped: total >= Self.maxMatches) }
        }
    }

    /// Adds results from a running search. Returns false if a newer search replaced it.
    private func append(_ chunk: [(URL, String, [TextSearch.Match])], generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        for (url, path, matches) in chunk {
            let file = FileResult(url: url, path: path)
            file.matches = matches.map { MatchRow(match: $0, file: file) }
            results.append(file)
            outline.reloadData()
            outline.expandItem(file)
        }
        updateStatus(done: false, capped: false)
        return true
    }

    private func finish(_ chunk: [(URL, String, [TextSearch.Match])], generation: Int, capped: Bool) {
        guard append(chunk, generation: generation) else { return }
        updateStatus(done: true, capped: capped)
    }

    private func updateStatus(done: Bool, capped: Bool) {
        let count = results.reduce(0) { $0 + $1.matches.count }
        let files = results.count
        if count == 0 {
            status.stringValue = done ? "No results" : "Searching…"
        } else {
            status.stringValue = "\(count)\(capped ? "+" : "") result\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
                + (done ? "" : "…")
        }
    }

    @objc private func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        switch outline.item(atRow: row) {
        case let hit as MatchRow: onOpen?(hit.file.url, hit.match)
        case let file as FileResult:
            outline.isItemExpanded(file) ? outline.collapseItem(file) : outline.expandItem(file)
        default: break
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FileResult)?.matches.count ?? (item == nil ? results.count : 0)
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? FileResult)?.matches[index] ?? results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is FileResult }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SearchResultCell ?? SearchResultCell(identifier: id)
        let text = cell.label
        switch item {
        case let file as FileResult:
            let name = (file.path as NSString).lastPathComponent
            let folder = (file.path as NSString).deletingLastPathComponent
            let s = NSMutableAttributedString(string: name, attributes: [.font: Chrome.fileFont, .foregroundColor: Chrome.text])
            if !folder.isEmpty {
                s.append(NSAttributedString(string: "  " + folder, attributes: [.font: Chrome.font, .foregroundColor: Chrome.faint]))
            }
            s.append(NSAttributedString(string: "  \(file.matches.count)", attributes: [.font: Chrome.font, .foregroundColor: Chrome.faint]))
            text.attributedStringValue = s
            text.maximumNumberOfLines = 1
        case let hit as MatchRow:
            let m = hit.match
            let s = NSMutableAttributedString(string: "\(m.line + 1)  ", attributes: [.font: Chrome.font, .foregroundColor: Chrome.faint])
            let preview = NSMutableAttributedString(string: m.preview, attributes: [.font: Chrome.font, .foregroundColor: Chrome.secondary])
            // Highlight the matched text (UTF-8 offsets → string range).
            let utf8 = m.preview.utf8
            if m.previewRange.upperBound <= utf8.count {
                let lo = utf8.index(utf8.startIndex, offsetBy: m.previewRange.lowerBound)
                let hi = utf8.index(utf8.startIndex, offsetBy: m.previewRange.upperBound)
                preview.addAttributes([.foregroundColor: Chrome.bright, .backgroundColor: Chrome.match],
                                      range: NSRange(lo..<hi, in: m.preview))
            }
            s.append(preview)
            text.attributedStringValue = s
            text.maximumNumberOfLines = 1
        default: break
        }
        return cell
    }
}

/// A result row. Its label isn't registered as the cell's `textField`, because AppKit restyles
/// that one on its own and would drop the colors, monospaced preview and highlight.
private final class SearchResultCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
