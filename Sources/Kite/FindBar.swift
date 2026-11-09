import AppKit
import EditorCore

/// One tab's find results: every match of the current query, found in the background.
///
/// Edits shift the list right away (dropping matches they touch) and mark it stale until the next
/// count lands, so highlights stay put while you type and the main thread never runs a regex
/// over the whole file.
@MainActor
final class FindState {
    /// Sorted, non-overlapping byte ranges. Empty matches (from `^`, `\b`) are included.
    private(set) var matches: [Range<Int>] = []
    /// True when there were more matches than are kept.
    private(set) var capped = false
    /// True when `matches` was counted for the current query and text.
    private(set) var isFresh = false
    /// Find in selection: the block find and replace stay inside. Moves with edits around it,
    /// and turns off if an edit crosses its edges.
    var scope: Range<Int>? { didSet { if scope != oldValue { invalidate() } } }
    /// Bumped on every edit, so a count started before it is thrown away.
    private(set) var editGeneration = 0
    /// Bumped when the query, options or scope change.
    private(set) var queryGeneration = 0
    /// Called after the list or scope changes, to redraw.
    var onChange: (() -> Void)?

    nonisolated static let maxMatches = 100_000

    init(buffer: TextBuffer) {
        buffer.addObserver { [weak self] edit in self?.shift(by: edit) }
    }

    /// The query changed (or find closed): drop the list.
    func invalidate() {
        queryGeneration += 1
        matches = []
        capped = false
        isFresh = false
        onChange?()
    }

    func set(_ matches: [Range<Int>], capped: Bool, queryGeneration: Int, editGeneration: Int) -> Bool {
        guard queryGeneration == self.queryGeneration, editGeneration == self.editGeneration else { return false }
        self.matches = matches
        self.capped = capped
        isFresh = true
        onChange?()
        return true
    }

    /// Sets the list directly (offscreen rendering).
    func show(_ matches: [Range<Int>]) {
        self.matches = matches
        capped = false
        isFresh = true
        onChange?()
    }

    private func shift(by edit: BufferEdit) {
        editGeneration += 1
        let delta = edit.newEndByte - edit.oldEndByte
        let start = edit.startByte, oldEnd = edit.oldEndByte
        if !matches.isEmpty {
            // Matches before the edit stay, ones it touches go, later ones move (in place: the
            // list can be long, and this runs on every keystroke).
            let first = FindQuery.firstIndex(in: matches) { !($0.upperBound < start || ($0.upperBound == start && !$0.isEmpty)) }
            let later = FindQuery.firstIndex(in: matches) { $0.lowerBound > oldEnd || ($0.lowerBound == oldEnd && start != oldEnd) }
            let cut = max(first, min(later, matches.count))
            if delta != 0 {
                matches.withUnsafeMutableBufferPointer { m in
                    for j in cut..<m.count { m[j] = (m[j].lowerBound + delta)..<(m[j].upperBound + delta) }
                }
            }
            if first < cut { matches.removeSubrange(first..<cut) }
        }
        if let s = scope {
            if oldEnd <= s.lowerBound && start < s.lowerBound {
                scope = (s.lowerBound + delta)..<(s.upperBound + delta)
            } else if start >= s.lowerBound && oldEnd <= s.upperBound {
                scope = s.lowerBound..<(s.upperBound + delta)
            } else if start > s.upperBound {
                // after it: unchanged
            } else {
                scope = nil
            }
        }
        isFresh = false
        onChange?()
    }
}

/// The find bar above the code: a find row, and with ⌥⌘F a replace row.
///
///     find    [ foo(\w+)       ]  3 of 12   case  word  regex  selection   ↑  ↓
///     replace [ bar$1          ]  replace  all
@MainActor
final class FindBar: ChromeView, NSTextFieldDelegate {
    /// The tab find works in.
    var pane: () -> EditorPane? = { nil }
    /// Puts the keyboard back in the code.
    var focusEditor: () -> Void = {}

    let findField = FindBar.field("text to find")
    let replaceField = FindBar.field("replace with")
    private let count = Chrome.label()
    private let caseButton = Chrome.textButton("case", target: nil, action: nil)
    private let wordButton = Chrome.textButton("word", target: nil, action: nil)
    private let regexButton = Chrome.textButton("regex", target: nil, action: nil)
    private let selectionButton = Chrome.textButton("selection", target: nil, action: nil)
    private let replaceRow = NSStackView()
    private var heightConstraint: NSLayoutConstraint!

    private var query: FindQuery?
    private var problem: FindQuery.Problem?
    /// What to do once the count for the current text lands.
    private var pendingAction: (() -> Void)?
    private var recountWork: DispatchWorkItem?
    /// The generations of the count running now, so a second one isn't started for the same text.
    private var inFlight: (query: Int, edit: Int)?
    /// Where typing in the find field searches from (where the selection was when find opened).
    private var typingAnchor = 0
    /// Shown in the count until the next search (e.g. "replaced 12").
    private var notice: String?

    static let rowHeight: CGFloat = 36
    /// Most cursors Select All Matches makes.
    static let maxCursors = 1000

    var options: FindOptions {
        FindOptions(caseSensitive: caseButton.isOn, wholeWord: wordButton.isOn, regex: regexButton.isOn)
    }

    var isShowingReplace: Bool { !replaceRow.isHidden }
    var isSearchingSelection: Bool { selectionButton.isOn }
    /// What the count says ("2 of 3", "bad regex"), for tests.
    var countText: String { count.stringValue }

    /// Types `text` into the find field, as if typed (for tests).
    func type(_ text: String) {
        findField.stringValue = text
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findField))
    }

    init() {
        super.init(frame: .zero)
        hairlines = [.maxY]
        findField.delegate = self
        replaceField.delegate = self
        findField.nextKeyView = replaceField
        replaceField.nextKeyView = findField

        let toggles: [(TextButton, Selector, String)] = [
            (caseButton, #selector(toggleCase(_:)), "Match case (⌥⌘C)"),
            (wordButton, #selector(toggleWord(_:)), "Whole word (⌥⌘W)"),
            (regexButton, #selector(toggleRegex(_:)), "Regular expression (⌥⌘R)"),
            (selectionButton, #selector(toggleSelection(_:)), "Only in the selected text (⌥⌘L)"),
        ]
        for (button, action, tip) in toggles {
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        let previous = Chrome.textButton("↑", target: self, action: #selector(findPrevious(_:)))
        let next = Chrome.textButton("↓", target: self, action: #selector(findNext(_:)))
        previous.toolTip = "Previous match (⇧⌘G)"
        next.toolTip = "Next match (⌘G)"
        let replaceOne = Chrome.textButton("replace", target: self, action: #selector(replaceCurrent(_:)))
        let replaceAll = Chrome.textButton("all", target: self, action: #selector(replaceAll(_:)))
        replaceOne.toolTip = "Replace this match and go to the next (Return)"
        replaceAll.toolTip = "Replace every match (⌥Return)"

        let findRow = row([Self.label("find"), findField, count, caseButton, wordButton, regexButton, selectionButton, previous, next])
        for v in [Self.label("replace"), replaceField, replaceOne, replaceAll] { replaceRow.addArrangedSubview(v) }
        style(replaceRow)
        replaceRow.isHidden = true
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rows = NSStackView(views: [findRow, replaceRow])
        rows.orientation = .vertical
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        heightConstraint = heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            findRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            replaceRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            findRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            replaceRow.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            heightConstraint,
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func field(_ placeholder: String) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        field.textColor = Chrome.text
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular), .foregroundColor: Chrome.faint,
        ])
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    private static func label(_ text: String) -> NSTextField {
        let label = Chrome.label(text)
        label.widthAnchor.constraint(equalToConstant: 52).isActive = true
        return label
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        style(row)
        return row
    }

    private func style(_ row: NSStackView) {
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        row.alignment = .centerY
    }

    // MARK: Showing and hiding

    /// Opens find (and replace, with `replacing`). A selection on one line becomes the search;
    /// one across several lines becomes the block to search in.
    func show(replacing: Bool) {
        guard let pane = pane() else { return }
        let editor = pane.editor
        let selected = editor.selectedText
        if replacing { replaceRow.isHidden = false } else if isHidden { replaceRow.isHidden = true }
        heightConstraint.constant = Self.rowHeight * (replaceRow.isHidden ? 1 : 2)
        let wasHidden = isHidden
        isHidden = false
        if !editor.selection.isEmpty && selected.contains("\n") {
            pane.find.scope = editor.selection.range
            selectionButton.isOn = true
        } else {
            if !selected.isEmpty { findField.stringValue = selected }
            if wasHidden { selectionButton.isOn = false; pane.find.scope = nil }
        }
        typingAnchor = editor.selection.range.lowerBound
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
        queryChanged()
    }

    func hide() {
        isHidden = true
        pendingAction = nil
        pane()?.find.invalidate()
        pane()?.editorView.showsFind = false
        focusEditor()
    }

    /// The active tab changed: search it with the same query.
    func paneChanged() {
        guard !isHidden, let pane = pane() else { return }
        pane.editorView.showsFind = true
        if selectionButton.isOn && pane.find.scope == nil { selectionButton.isOn = false }
        pane.find.invalidate()
        recount(delay: 0)
    }

    /// The text changed (typing in the code): count again after a short pause.
    func textChanged() {
        guard !isHidden else { return }
        if selectionButton.isOn && pane()?.find.scope == nil { selectionButton.isOn = false }
        recount(delay: 0.15)
    }

    // MARK: Query

    func useSelection() {
        guard let pane = pane() else { return }
        let text = pane.editor.selectedText
        guard !text.isEmpty else { return }
        findField.stringValue = text
        if !isHidden { queryChanged() } else { compile() }
    }

    @discardableResult
    private func compile() -> FindQuery? {
        do {
            query = try FindQuery(findField.stringValue, options: options)
            problem = nil
        } catch {
            query = nil
            problem = error
        }
        return query
    }

    private func queryChanged() {
        notice = nil
        compile()
        guard let pane = pane() else { return }
        pane.editorView.showsFind = !isHidden
        pane.find.invalidate()
        updateCount()
        recount(delay: 0)
    }

    /// Counts matches in the background, then runs any action waiting for them.
    private func recount(delay: TimeInterval) {
        recountWork?.cancel()
        guard let pane = pane() else { return }
        let state = pane.find
        guard query != nil else { updateCount(); return }
        let work = DispatchWorkItem { [weak self, weak pane] in
            MainActor.assumeIsolated {
                guard let self, let pane, pane === self.pane(), let query = self.query else { return }
                let storage = pane.editor.buffer.storage
                let scope = state.scope
                let generations = (state.queryGeneration, state.editGeneration)
                if let running = self.inFlight, running == generations { return }
                self.inFlight = generations
                Task.detached(priority: .userInitiated) { [weak self] in
                    let text = String(decoding: storage.allBytes, as: UTF8.self)
                    let found = query.matches(in: text, within: scope, limit: FindState.maxMatches + 1)
                    let capped = found.count > FindState.maxMatches
                    await MainActor.run {
                        if let self, let running = self.inFlight, running == generations { self.inFlight = nil }
                        guard state.set(capped ? Array(found.prefix(FindState.maxMatches)) : found, capped: capped,
                                        queryGeneration: generations.0, editGeneration: generations.1) else { return }
                        self?.countLanded()
                    }
                }
            }
        }
        recountWork = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.perform()
        }
    }

    private func countLanded() {
        if let action = pendingAction {
            pendingAction = nil
            action()
        }
        updateCount()
    }

    /// Runs `action` with fresh matches: now if they're ready, else once they are.
    private func withFreshMatches(_ action: @escaping (FindState) -> Void) {
        guard let pane = pane() else { return }
        let state = pane.find
        if query == nil { NSSound.beep(); return }
        if state.isFresh {
            action(state)
        } else {
            pendingAction = { [weak self] in
                guard let current = self?.pane(), current === pane else { return }
                action(state)
            }
            recount(delay: 0)
        }
    }

    func updateCount() {
        guard let pane = pane() else { count.stringValue = ""; return }
        count.textColor = Chrome.dim
        if problem == .invalid {
            count.stringValue = "bad regex"
            count.textColor = Chrome.error
            return
        }
        if let notice { count.stringValue = notice; return }
        guard query != nil else { count.stringValue = ""; return }
        let state = pane.find
        guard state.isFresh else { return }   // keep the last count until the new one lands
        let n = state.matches.count
        let total = state.capped ? "\(n)+" : "\(n)"
        let main = pane.editor.selection.range
        if n == 0 {
            count.stringValue = "no matches"
        } else if let i = index(of: main, in: state.matches) {
            count.stringValue = "\(i + 1) of \(total)"
        } else {
            count.stringValue = n == 1 ? "1 match" : "\(total) matches"
        }
    }

    private func index(of range: Range<Int>, in matches: [Range<Int>]) -> Int? {
        let i = FindQuery.firstIndex(in: matches) { $0.lowerBound >= range.lowerBound }
        return i < matches.count && matches[i] == range ? i : nil
    }

    // MARK: Options

    @objc func toggleCase(_ sender: Any?) { caseButton.isOn.toggle(); queryChanged() }
    @objc func toggleWord(_ sender: Any?) { wordButton.isOn.toggle(); queryChanged() }
    @objc func toggleRegex(_ sender: Any?) { regexButton.isOn.toggle(); queryChanged() }

    @objc func toggleSelection(_ sender: Any?) {
        guard let pane = pane() else { return }
        if selectionButton.isOn {
            selectionButton.isOn = false
            pane.find.scope = nil
        } else if !pane.editor.selection.isEmpty {
            selectionButton.isOn = true
            pane.find.scope = pane.editor.selection.range
        } else {
            NSSound.beep()
            return
        }
        queryChanged()
    }

    // MARK: Going to matches

    @objc func findNext(_ sender: Any?) { go(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { go(backwards: true) }

    private func go(backwards: Bool) {
        guard pane() != nil else { return }
        if isHidden { show(replacing: false); return }
        notice = nil
        withFreshMatches { [weak self] state in
            guard let self, let editor = self.pane()?.editor else { return }
            guard let r = FindQuery.next(in: state.matches, after: editor.selection.range, backwards: backwards) else {
                NSSound.beep(); return
            }
            editor.setSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
            self.typingAnchor = r.lowerBound
            self.updateCount()
        }
    }

    /// While typing a search, jump to the first match from where find opened.
    private func jumpWhileTyping() {
        withFreshMatches { [weak self] state in
            guard let self, let editor = self.pane()?.editor else { return }
            let matches = state.matches.filter { !$0.isEmpty }
            guard !matches.isEmpty else { return }
            let i = FindQuery.firstIndex(in: matches) { $0.lowerBound >= self.typingAnchor }
            let r = i < matches.count ? matches[i] : matches[0]
            editor.setSelection(Selection(anchor: r.lowerBound, head: r.upperBound))
        }
    }

    /// Puts a cursor on every match (⌥Return, ⌃⌘G), the main one at the next match.
    @objc func selectAllMatches(_ sender: Any?) {
        if isHidden { show(replacing: false) }
        withFreshMatches { [weak self] state in
            guard let self, let editor = self.pane()?.editor else { return }
            let matches = state.matches.filter { !$0.isEmpty }
            guard !matches.isEmpty else { NSSound.beep(); return }
            guard matches.count <= Self.maxCursors else {
                // Every keystroke edits at each cursor, which gets slow past this many.
                NSSound.beep()
                self.notice = "\(matches.count) is too many cursors (max \(Self.maxCursors)): try replace"
                self.updateCount()
                return
            }
            let selections = matches.map { Selection(anchor: $0.lowerBound, head: $0.upperBound) }
            let i = FindQuery.firstIndex(in: matches) { $0.lowerBound >= editor.selection.range.lowerBound }
            editor.setSelections(main: selections[i < matches.count ? i : 0], others: selections)
            self.focusEditor()
        }
    }

    // MARK: Replacing

    /// Replaces the selected match, if it is one, then goes to the next match.
    @objc func replaceCurrent(_ sender: Any?) {
        guard let pane = pane(), let query else { NSSound.beep(); return }
        let editor = pane.editor
        let range = editor.selection.range
        notice = nil
        let inScope = pane.find.scope.map { $0.lowerBound <= range.lowerBound && range.upperBound <= $0.upperBound } ?? true
        if inScope, let text = query.replacement(forMatchAt: range, in: editor.text, template: replaceField.stringValue) {
            editor.replace([(range, text)])
            editor.setSelection(Selection(caret: range.lowerBound + text.utf8.count))
        }
        go(backwards: false)
    }

    /// Replaces every match (inside the selection block, if that's on) as one undo step.
    @objc func replaceAll(_ sender: Any?) {
        guard let pane = pane(), let query else { NSSound.beep(); return }
        let state = pane.find
        let template = replaceField.stringValue
        let storage = pane.editor.buffer.storage
        let scope = state.scope
        let generation = state.editGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let text = String(decoding: storage.allBytes, as: UTF8.self)
            let edits = query.replacements(in: text, within: scope, template: template)
            await MainActor.run {
                guard let self, self.pane() === pane, state.editGeneration == generation else { return }
                guard !edits.isEmpty else { NSSound.beep(); return }
                pane.editor.replace(edits)   // the selection block grows or shrinks with the edits inside it
                self.notice = edits.count == 1 ? "replaced 1" : "replaced \(edits.count)"
                self.updateCount()
            }
        }
    }

    // MARK: Field keys

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === findField else { return }
        queryChanged()
        if !findField.stringValue.isEmpty { jumpWhileTyping() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // ⌥Return arrives as "insert newline ignoring field editor".
        let option = selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            if control === replaceField {
                option ? replaceAll(nil) : replaceCurrent(nil)
            } else if option {
                selectAllMatches(nil)
            } else {
                NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? findPrevious(nil) : findNext(nil)
            }
        default:
            return false
        }
        return true
    }
}
