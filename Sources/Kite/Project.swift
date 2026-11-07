import AppKit
import CoreServices

/// A folder opened as a project: its file tree for the sidebar, a flat list of every file
/// (for quick open and search), and a watch that keeps both current when files change on disk.
@MainActor
final class Project {
    /// Posted with `object: project` when folders' contents changed; `userInfo["nodes"]` holds the reloaded nodes.
    static let treeDidChange = Notification.Name("KiteProjectTreeDidChange")
    /// Posted with `object: project` when the flat file list has been rebuilt.
    static let filesDidChange = Notification.Name("KiteProjectFilesDidChange")

    private(set) static var all: [Project] = []
    /// The project the next untitled window should belong to (set by File ▸ Open Folder).
    static var pendingForNewWindow: Project?

    /// Folders and files never shown or searched: version control, build output, dependencies.
    nonisolated static let ignoredNames: Set<String> = [
        ".git", ".hg", ".svn", ".build", "build", "node_modules", ".swiftpm", "DerivedData",
        "__pycache__", ".venv", "venv", ".mypy_cache", ".pytest_cache", ".DS_Store", ".idea",
    ]
    nonisolated static let maxIndexedFiles = 50_000

    let root: URL
    let tree: FileNode
    var name: String { root.lastPathComponent }
    /// Every file in the project, relative paths sorted. Filled in the background after opening.
    private(set) var files: [URL] = []
    private(set) var isIndexed = false

    private var stream: FSEventStreamRef?
    private var indexing = false
    private var indexAgain = false

    /// Opens a folder as a project, or returns it if it's already open.
    static func open(_ url: URL) -> Project {
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        if let existing = all.first(where: { $0.root == root }) { return existing }
        let project = Project(root: root)
        all.append(project)
        return project
    }

    /// The open project whose folder holds `url` (the deepest one, if projects nest).
    static func containing(_ url: URL?) -> Project? {
        guard let path = url?.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return all.filter { path.hasPrefix($0.root.path + "/") }.max { $0.root.path.count < $1.root.path.count }
    }

    private init(root: URL) {
        self.root = root
        tree = FileNode(url: root, isDirectory: true, parent: nil)
        startWatching()
        reindex()
    }

    /// The path of `url` inside the project, like `Sources/Kite/main.swift`.
    func relativePath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : url.lastPathComponent
    }

    // MARK: Watching for changes

    private func startWatching() {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let project = Unmanaged<Project>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { project.foldersChanged(changed) }   // the stream runs on the main queue
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func foldersChanged(_ paths: [String]) {
        var reloaded: [FileNode] = []
        for path in Set(paths) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard let node = tree.loadedNode(at: url, under: root) else { continue }
            node.reload()
            reloaded.append(node)
        }
        if !reloaded.isEmpty {
            NotificationCenter.default.post(name: Self.treeDidChange, object: self, userInfo: ["nodes": reloaded])
        }
        reindex()
    }

    // MARK: Flat file list

    private func reindex() {
        if indexing { indexAgain = true; return }
        indexing = true
        let root = self.root
        Task.detached(priority: .utility) {
            let list = Project.listFiles(under: root)
            await MainActor.run {
                self.files = list
                self.isIndexed = true
                self.indexing = false
                NotificationCenter.default.post(name: Project.filesDidChange, object: self)
                if self.indexAgain { self.indexAgain = false; self.reindex() }
            }
        }
    }

    nonisolated static func listFiles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager().enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker {
            if ignoredNames.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            if (try? url.resourceValues(forKeys: Set(keys)))?.isRegularFile == true { files.append(url) }
            if files.count >= maxIndexedFiles { break }
        }
        return files
    }
}

/// One file or folder in the sidebar tree. Folder contents load the first time they're shown.
@MainActor
final class FileNode {
    let url: URL
    let isDirectory: Bool
    private(set) weak var parent: FileNode?
    private var loaded: [FileNode]?

    var name: String { url.lastPathComponent }

    init(url: URL, isDirectory: Bool, parent: FileNode?) {
        self.url = url
        self.isDirectory = isDirectory
        self.parent = parent
    }

    var children: [FileNode] {
        if let loaded { return loaded }
        let fresh = load(reusing: [:])
        loaded = fresh
        return fresh
    }

    /// Re-reads the folder, keeping the node objects (and so the expanded state) of entries that remain.
    func reload() {
        guard let current = loaded else { return }
        loaded = load(reusing: Dictionary(uniqueKeysWithValues: current.map { ($0.url, $0) }))
    }

    private func load(reusing existing: [URL: FileNode]) -> [FileNode] {
        guard isDirectory else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let nodes = items.compactMap { item -> FileNode? in
            let item = item.standardizedFileURL
            guard !Project.ignoredNames.contains(item.lastPathComponent) else { return nil }
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if let node = existing[item], node.isDirectory == isDirectory { return node }
            return FileNode(url: item, isDirectory: isDirectory, parent: self)
        }
        // Folders first, then files, in Finder's natural order (file2 before file10).
        return nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// The already-loaded node for `target`, walking down from this (root) node. Nil if any folder
    /// on the way hasn't been opened yet, since there's nothing on screen to refresh then.
    func loadedNode(at target: URL, under root: URL) -> FileNode? {
        if target == url { return self }
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        var node: FileNode = self
        for part in target.path.dropFirst(root.path.count + 1).split(separator: "/") {
            guard let children = node.loaded, let next = children.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    /// Nodes from the top folder down to this one (for expanding the sidebar to reveal a file).
    func path(from root: URL) -> [FileNode]? {
        var chain: [FileNode] = []
        var node: FileNode? = self
        while let n = node { chain.insert(n, at: 0); node = n.parent }
        return chain.first?.url == root ? chain : nil
    }
}
