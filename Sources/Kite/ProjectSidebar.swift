import AppKit
import EditorCore

/// The project's file list: text only. Folders end in "/", closed folders are dimmer, and the
/// open file is brighter. Clicking a file opens it; clicking a folder opens or closes it.
@MainActor
final class ProjectSidebar: ChromeView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let project: Project
    /// Called with a file the user picked, and the search match to select in it, if any.
    var onOpen: ((URL, TextSearch.Match?) -> Void)?

    private let outline = QuietOutlineView()
    private let scroll = NSScrollView()
    private let header = ChromeView()
    private let filesButton = Chrome.textButton("files", target: nil, action: nil)
    private let searchButton = Chrome.textButton("search", target: nil, action: nil)
    private let body = NSView()
    private var activeURL: URL?
    /// Project search (and replace). Made the first time it's shown.
    private(set) lazy var search: ProjectSearchView = {
        let view = ProjectSearchView(project: project)
        view.onOpen = { [weak self] url, match in self?.onOpen?(url, match) }
        view.onReplace = { [weak self] plans, query, template in self?.onReplace?(plans, query, template) }
        view.openFiles = { ProjectReplace.openTexts() }
        return view
    }()
    /// Called when project search asks to replace.
    var onReplace: (([ProjectReplace.FilePlan], FindQuery, String) -> Void)?

    init(project: Project) {
        self.project = project
        super.init(frame: NSRect(x: 0, y: 0, width: 232, height: 400))

        // Header: files / search, past the window buttons. The project's name is in the status line.
        header.hairlines = [.maxY]
        header.toolTip = project.root.path
        filesButton.target = self
        filesButton.action = #selector(showFilesAction(_:))
        filesButton.isOn = true
        searchButton.target = self
        searchButton.action = #selector(showSearchAction(_:))
        searchButton.toolTip = "Search in project (⇧⌘F)"
        for v in [filesButton, searchButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.selectionHighlightStyle = .none
        outline.rowSizeStyle = .custom
        outline.rowHeight = 26
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 16
        outline.indentationMarkerFollowsCell = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.setAccessibilityLabel("Project files")
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        scroll.automaticallyAdjustsContentInsets = false

        for v in [header, body, scroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(header)
        addSubview(body)
        body.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Chrome.barHeight),
            filesButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 84),
            filesButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            searchButton.leadingAnchor.constraint(equalTo: filesButton.trailingAnchor, constant: 12),
            searchButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: body.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])

        NotificationCenter.default.addObserver(forName: Project.treeDidChange, object: project, queue: .main) { [weak self] note in
            let nodes = note.userInfo?["nodes"] as? [FileNode] ?? []
            MainActor.assumeIsolated { self?.reload(nodes) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func reload(_ nodes: [FileNode]) {
        for node in nodes {
            outline.reloadItem(node === project.tree ? nil : node, reloadChildren: true)
        }
    }

    /// Expands the folders above a file and marks it as the open one.
    func reveal(_ url: URL?, scroll: Bool = true) {
        let url = url?.resolvingSymlinksInPath().standardizedFileURL
        let previous = activeURL
        activeURL = url
        if let previous, let node = node(for: previous, expanding: false) { outline.reloadItem(node) }
        guard let url, url.path.hasPrefix(project.root.path + "/"), let node = node(for: url, expanding: true) else { return }
        outline.reloadItem(node)
        let row = outline.row(forItem: node)
        if scroll, row >= 0 { outline.scrollRowToVisible(row) }
    }

    private func node(for url: URL, expanding: Bool) -> FileNode? {
        guard url.path.hasPrefix(project.root.path + "/") else { return nil }
        var node = project.tree
        for part in url.path.dropFirst(project.root.path.count + 1).split(separator: "/") {
            if !expanding && node !== project.tree && !outline.isItemExpanded(node) { return nil }
            guard let next = node.children.first(where: { $0.name == part }) else { return nil }
            if expanding && node !== project.tree { outline.expandItem(node) }
            node = next
        }
        return node
    }

    @objc private func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
        } else {
            onOpen?(node.url, nil)
        }
    }

    // MARK: Files / Search

    @objc private func showFilesAction(_ sender: Any?) { showFiles() }
    @objc private func showSearchAction(_ sender: Any?) { showSearch() }

    func showFiles() {
        filesButton.isOn = true
        searchButton.isOn = false
        search.removeFromSuperview()
        scroll.isHidden = false
    }

    /// Switches to project search and puts the cursor in its field.
    func showSearch(with text: String? = nil) {
        filesButton.isOn = false
        searchButton.isOn = true
        scroll.isHidden = true
        if search.superview == nil {
            search.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(search)
            NSLayoutConstraint.activate([
                search.leadingAnchor.constraint(equalTo: body.leadingAnchor),
                search.trailingAnchor.constraint(equalTo: body.trailingAnchor),
                search.topAnchor.constraint(equalTo: body.topAnchor),
                search.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            ])
        }
        search.focus(with: text)
    }

    // MARK: Data source

    private func node(_ item: Any?) -> FileNode { (item as? FileNode) ?? project.tree }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        node(item).children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        node(item).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        node(item).isDirectory
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? FileCell ?? FileCell(identifier: id)
        let file = node(item)
        let color: NSColor
        if file.isDirectory {
            color = outlineView.isItemExpanded(file) ? Chrome.dim : Chrome.faint
        } else {
            color = file.url == activeURL ? Chrome.bright : Chrome.secondary
        }
        cell.label.stringValue = file.isDirectory ? file.name + "/" : file.name
        cell.label.textColor = color
        return cell
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] { outline.reloadItem(item) }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let item = notification.userInfo?["NSObject"] { outline.reloadItem(item) }
    }
}

/// An outline without disclosure triangles: folders say what they are with a trailing slash.
final class QuietOutlineView: NSOutlineView {
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
}

/// One row of the file list. Its label isn't registered as the cell's `textField`, so AppKit
/// leaves its colors alone.
private final class FileCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = Chrome.fileFont
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
