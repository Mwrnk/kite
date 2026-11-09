import AppKit
import EditorCore

/// Search, and replace, across every file in the project (⌘⇧F). Results are grouped by file and
/// fill in as they're found. Files open in Kite are searched as they are on screen, unsaved
/// edits included.
///
/// With text in the replace field each match shows what it becomes (`-` old, `+` new). Then a
/// click skips a match or a whole file, a double-click opens it, and the button at the bottom
/// replaces the rest.
@MainActor
final class ProjectSearchView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate {
    /// Called with a file and the match to select in it.
    var onOpen: ((URL, TextSearch.Match) -> Void)?
    /// Called to replace: the files with what was previewed, the query and the replacement.
    var onReplace: (([ProjectReplace.FilePlan], FindQuery, String) -> Void)?
    /// The text of files open in Kite, by path (searched instead of what's on disk).
    var openFiles: () -> [String: String] = { [:] }

    private let project: Project
    private let field = ProjectSearchView.field("search in project")
    private let replaceField = ProjectSearchView.field("replace with")
    private let caseButton = Chrome.textButton("case", target: nil, action: nil)
    private let wordButton = Chrome.textButton("word", target: nil, action: nil)
    private let regexButton = Chrome.textButton("regex", target: nil, action: nil)
    private let status = Chrome.label()
    private let replaceButton = Chrome.textButton("replace", target: nil, action: nil)
    private let outline = QuietOutlineView()
    private var results: [FileResult] = []
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var searchedQuery: FindQuery?
    private var searchedTemplate: String?
    private var searchDone = false
    private var capped = false
    /// A report shown in the status line until the next search ("Replaced 12 in 3 files").
    private var notice: String?

    /// Most results shown while just searching, and while replacing (when every match has to be seen).
    nonisolated static let maxMatches = 2000
    nonisolated static let maxReplaceMatches = 20_000

    final class FileResult {
        let url: URL
        let path: String
        var matches: [MatchRow] = []
        init(url: URL, path: String) { self.url = url; self.path = path }
        var allSkipped: Bool { matches.allSatisfy(\.skipped) }
    }

    final class MatchRow {
        let match: TextSearch.Match
        unowned let file: FileResult
        var skipped = false
        init(match: TextSearch.Match, file: FileResult) { self.match = match; self.file = file }
    }

    init(project: Project) {
        self.project = project
        super.init(frame: .zero)

        for f in [field, replaceField] { f.delegate = self }
        field.placeholderString = nil
        field.placeholderAttributedString = NSAttributedString(string: "search in \(project.name)", attributes: [
            .font: Chrome.fileFont, .foregroundColor: Chrome.faint,
        ])
        field.nextKeyView = replaceField
        replaceField.nextKeyView = field
        for (button, action, tip) in [(caseButton, #selector(toggleCase(_:)), "Match case"),
                                      (wordButton, #selector(toggleWord(_:)), "Whole word"),
                                      (regexButton, #selector(toggleRegex(_:)), "Regular expression")] {
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        replaceButton.target = self
        replaceButton.action = #selector(replaceAction(_:))
        replaceButton.isHidden = true
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
        outline.doubleAction = #selector(doubleClicked(_:))
        outline.setAccessibilityLabel("Search results")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let toggles = NSStackView(views: [caseButton, wordButton, regexButton])
        toggles.spacing = 14
        let stack = NSStackView(views: [field, replaceField, toggles, status, replaceButton, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(12, after: toggles)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [field, replaceField, status] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true }
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

    private static func field(_ placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Chrome.fileFont
        field.textColor = Chrome.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: Chrome.fileFont, .foregroundColor: Chrome.faint,
        ])
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        return field
    }

    /// True while the replace field has text: results preview the change and clicks skip.
    private var isReplacing: Bool { !replaceField.stringValue.isEmpty }

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
        if selector == #selector(NSResponder.insertNewline(_:)), control === field, !isReplacing,
           let first = results.first?.matches.first {
            onOpen?(first.file.url, first.match)   // Return opens the first result
            return true
        }
        return false
    }

    // MARK: Running a search

    func controlTextDidChange(_ obj: Notification) { queryChanged(nil) }

    @objc private func toggleCase(_ sender: Any?) { caseButton.isOn.toggle(); queryChanged(nil) }
    @objc private func toggleWord(_ sender: Any?) { wordButton.isOn.toggle(); queryChanged(nil) }
    @objc private func toggleRegex(_ sender: Any?) { regexButton.isOn.toggle(); queryChanged(nil) }

    @objc private func queryChanged(_ sender: Any?) {
        notice = nil
        // Wait for a short pause in typing before searching.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.startSearch() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Shows a report, then searches again (after a replace).
    func refresh(notice: String) {
        self.notice = notice
        startSearch()
    }

    private func startSearch() {
        generation += 1
        let myGeneration = generation
        results = []
        searchDone = false
        capped = false
        outline.reloadData()
        replaceButton.isHidden = true
        let pattern = field.stringValue
        searchedQuery = nil
        guard !pattern.isEmpty else { status.stringValue = ""; return }
        let options = FindOptions(caseSensitive: caseButton.isOn, wholeWord: wordButton.isOn, regex: regexButton.isOn)
        guard let query = try? FindQuery(pattern, options: options) else {
            status.stringValue = "bad regex"
            status.textColor = Chrome.error
            return
        }
        status.textColor = Chrome.dim
        status.stringValue = "Searching…"
        let template: String? = isReplacing ? replaceField.stringValue : nil
        searchedQuery = query
        searchedTemplate = template
        let limit = template == nil ? Self.maxMatches : Self.maxReplaceMatches

        let files = project.files
        let paths = files.map { project.relativePath($0) }
        let open = openFiles()
        Task.detached(priority: .userInitiated) { [weak self] in
            var batch: [(URL, String, [TextSearch.Match])] = []
            var total = 0
            var lastFlush = Date()
            for (url, path) in zip(files, paths) {
                let text: String
                if let onScreen = open[ProjectReplace.key(url)] {
                    text = onScreen
                } else {
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                          let decoded = TextSearch.text(of: data) else { continue }
                    text = decoded
                }
                let perFile = template == nil ? 200 : limit
                let found = TextSearch.matches(of: query, in: text, template: template, limit: min(perFile, limit - total + 1))
                if !found.isEmpty { batch.append((url, path, Array(found.prefix(limit - total)))); total += found.count }
                // Hand results over in batches, so the list fills in as the search goes.
                if !batch.isEmpty && (Date().timeIntervalSince(lastFlush) > 0.1 || total >= limit) {
                    let chunk = batch
                    batch = []
                    lastFlush = Date()
                    let stillCurrent = await MainActor.run { self?.append(chunk, generation: myGeneration) ?? false }
                    if !stillCurrent { return }
                }
                if total >= limit { break }
            }
            let chunk = batch
            await MainActor.run { self?.finish(chunk, generation: myGeneration, capped: total >= limit) }
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
        updateStatus()
        return true
    }

    private func finish(_ chunk: [(URL, String, [TextSearch.Match])], generation: Int, capped: Bool) {
        guard append(chunk, generation: generation) else { return }
        searchDone = true
        self.capped = capped
        updateStatus()
    }

    private func updateStatus() {
        let count = results.reduce(0) { $0 + $1.matches.count }
        let files = results.count
        let more = capped ? "+" : ""
        if let notice, searchDone {
            status.stringValue = notice + (count == 0 ? "" : " · \(count)\(more) still match")
        } else if count == 0 {
            status.stringValue = searchDone ? "No results" : "Searching…"
        } else if searchedTemplate != nil {
            status.stringValue = "\(count)\(more) in \(files) file\(files == 1 ? "" : "s") · click skips, double-click opens"
        } else {
            status.stringValue = "\(count)\(more) result\(count == 1 ? "" : "s") in \(files) file\(files == 1 ? "" : "s")"
                + (searchDone ? "" : "…")
        }
        updateReplaceButton()
    }

    private func updateReplaceButton() {
        guard searchedTemplate != nil, searchDone, !results.isEmpty else { replaceButton.isHidden = true; return }
        replaceButton.isHidden = false
        if capped {
            replaceButton.text = "too many matches to replace: narrow the search"
            replaceButton.isEnabled = false
            return
        }
        let kept = results.map { $0.matches.filter { !$0.skipped }.count }
        let count = kept.reduce(0, +)
        let files = kept.filter { $0 > 0 }.count
        replaceButton.isEnabled = count > 0
        replaceButton.isOn = count > 0
        replaceButton.text = count == 0 ? "nothing to replace"
            : "replace \(count) in \(files) file\(files == 1 ? "" : "s")"
    }

    @objc private func replaceAction(_ sender: Any?) {
        guard let query = searchedQuery, let template = searchedTemplate, searchDone, !capped else { return }
        let plans = results.compactMap { file -> ProjectReplace.FilePlan? in
            let skip = Set(file.matches.filter(\.skipped).map(\.match.offset))
            guard skip.count < file.matches.count else { return nil }
            return ProjectReplace.FilePlan(url: file.url, previewed: file.matches.map(\.match.offset), skip: skip)
        }
        guard !plans.isEmpty else { return }
        onReplace?(plans, query, template)
    }

    // MARK: Test hooks (KITE_TEST_SCRIPT)

    func testSearch(_ pattern: String, replace: String) {
        field.stringValue = pattern
        replaceField.stringValue = replace
        notice = nil
        startSearch()
    }
    var testStatus: String { status.stringValue }
    var testButton: String { replaceButton.isHidden ? "" : replaceButton.text }
    var testFiles: [(name: String, count: Int)] { results.map { (($0.path as NSString).lastPathComponent, $0.matches.count) } }
    func testSkip(file name: String) {
        guard let file = results.first(where: { ($0.path as NSString).lastPathComponent == name }) else { return }
        for m in file.matches { m.skipped = true }
        updateReplaceButton()
    }
    func testReplace() { replaceAction(nil) }

    // MARK: Clicks

    @objc private func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if searchedTemplate != nil {
            // Replacing: a click skips (or un-skips) a match, or every match in a file.
            switch item {
            case let hit as MatchRow:
                hit.skipped.toggle()
                outline.reloadItem(hit)
                outline.reloadItem(hit.file)
            case let file as FileResult:
                let skip = !file.allSkipped
                for m in file.matches { m.skipped = skip }
                outline.reloadItem(file, reloadChildren: true)
            default: break
            }
            updateReplaceButton()
            return
        }
        switch item {
        case let hit as MatchRow: onOpen?(hit.file.url, hit.match)
        case let file as FileResult:
            outline.isItemExpanded(file) ? outline.collapseItem(file) : outline.expandItem(file)
        default: break
        }
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard searchedTemplate != nil, outline.clickedRow >= 0 else { return }
        switch outline.item(atRow: outline.clickedRow) {
        case let hit as MatchRow:
            hit.skipped.toggle()   // undo the single click's skip
            outline.reloadItem(hit)
            updateReplaceButton()
            onOpen?(hit.file.url, hit.match)
        case let file as FileResult:
            for m in file.matches { m.skipped.toggle() }
            outline.reloadItem(file, reloadChildren: true)
            updateReplaceButton()
            if let first = file.matches.first { onOpen?(file.url, first.match) }
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
            let faded = searchedTemplate != nil && file.allSkipped
            let name = (file.path as NSString).lastPathComponent
            let folder = (file.path as NSString).deletingLastPathComponent
            let s = NSMutableAttributedString(string: name, attributes: [.font: Chrome.fileFont, .foregroundColor: faded ? Chrome.faint : Chrome.text])
            if !folder.isEmpty {
                s.append(NSAttributedString(string: "  " + folder, attributes: [.font: Chrome.font, .foregroundColor: Chrome.faint]))
            }
            let kept = file.matches.filter { !$0.skipped }.count
            let count = searchedTemplate != nil && kept != file.matches.count ? "\(kept)/\(file.matches.count)" : "\(file.matches.count)"
            s.append(NSAttributedString(string: "  " + count, attributes: [.font: Chrome.font, .foregroundColor: Chrome.faint]))
            text.attributedStringValue = s
            text.maximumNumberOfLines = 1
        case let hit as MatchRow:
            text.attributedStringValue = searchedTemplate != nil ? replacePreview(hit) : searchPreview(hit.match)
            text.maximumNumberOfLines = searchedTemplate != nil ? 2 : 1
        default: break
        }
        return cell
    }

    private func searchPreview(_ m: TextSearch.Match) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "\(m.line + 1)  ", attributes: [.font: Chrome.font, .foregroundColor: Chrome.faint])
        let preview = NSMutableAttributedString(string: m.preview, attributes: [.font: Chrome.font, .foregroundColor: Chrome.secondary])
        if let range = Self.nsRange(m.previewRange, in: m.preview) {
            preview.addAttributes([.foregroundColor: Chrome.bright, .backgroundColor: Chrome.match], range: range)
        }
        s.append(preview)
        return s
    }

    /// Two lines: `- ` the line as it is, `+ ` the line as it will be. Skipped matches are faint.
    private func replacePreview(_ hit: MatchRow) -> NSAttributedString {
        let m = hit.match
        let base: NSColor = hit.skipped ? Chrome.faint : Chrome.secondary
        let s = NSMutableAttributedString()
        let old = NSMutableAttributedString(string: "- " + m.preview, attributes: [.font: Chrome.font, .foregroundColor: base])
        if !hit.skipped, let r = Self.nsRange(m.previewRange, in: m.preview) {
            old.addAttributes([.foregroundColor: Chrome.error, .strikethroughStyle: NSUnderlineStyle.single.rawValue],
                              range: NSRange(location: r.location + 2, length: r.length))
        }
        s.append(old)
        // The new line: the preview with the matched part swapped for the replacement.
        let bytes = Array(m.preview.utf8)
        let before = String(decoding: bytes[..<m.previewRange.lowerBound], as: UTF8.self)
        let after = String(decoding: bytes[m.previewRange.upperBound...], as: UTF8.self)
        let inserted = (m.replacement ?? "").replacingOccurrences(of: "\n", with: "⏎")
        let new = NSMutableAttributedString(string: "\n+ " + before, attributes: [.font: Chrome.font, .foregroundColor: base])
        new.append(NSAttributedString(string: inserted, attributes: [
            .font: Chrome.font, .foregroundColor: hit.skipped ? Chrome.faint : Chrome.added,
        ]))
        new.append(NSAttributedString(string: after, attributes: [.font: Chrome.font, .foregroundColor: base]))
        s.append(new)
        return s
    }

    private static func nsRange(_ utf8Range: Range<Int>, in text: String) -> NSRange? {
        let utf8 = text.utf8
        guard utf8Range.upperBound <= utf8.count else { return nil }
        let lo = utf8.index(utf8.startIndex, offsetBy: utf8Range.lowerBound)
        let hi = utf8.index(utf8.startIndex, offsetBy: utf8Range.upperBound)
        return NSRange(lo..<hi, in: text)
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
