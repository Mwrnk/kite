import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build(recentDelegate: self)
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    private func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { MainActor.assumeIsolated { _ = NSApp.presentError(error) } }
        }
    }

    @objc func openFolderPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open Folder"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.openFolder(url) }
        }
    }

    /// Opens a folder as a project in a new window, or brings forward the window already showing it.
    func openFolder(_ url: URL) {
        let project = Project.open(url)
        RecentFolders.add(project.root)
        // Windows already showing files from this folder join the project; if any do, use them.
        let joined = NSApp.windows.filter { ($0.windowController as? EditorWindowController)?.adopt(project) == true }
        if let window = joined.first {
            window.makeKeyAndOrderFront(nil)
            return
        }
        Project.pendingForNewWindow = project
        NSDocumentController.shared.newDocument(nil)
        Project.pendingForNewWindow = nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Development aid: KITE_SNAPSHOT=/path.png saves the front window, as drawn, after 2.5 s.
        guard let path = ProcessInfo.processInfo.environment["KITE_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                guard let view = NSApp.orderedWindows.first?.contentView?.superview ?? NSApp.orderedWindows.first?.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                      let layer = view.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
                layer.render(in: ctx.cgContext)   // the bitmap context is already at the screen's scale
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !CommandLine.arguments.dropFirst().contains { !$0.hasPrefix("-") }
    }

    // Fills File ▸ Open Recent each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in RecentFolders.list {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }
}

/// Every open request (command line, Finder, Dock, Open Recent, the Open panel) passes through here,
/// so folders can become projects instead of failing as documents.
final class KiteDocumentController: NSDocumentController {
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            (NSApp.delegate as? AppDelegate)?.openFolder(url)
            completionHandler(nil, false, nil)
            return
        }
        super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
    }

    /// File ▸ Open… can pick a folder too.
    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.canChooseDirectories = true
        super.beginOpenPanel(openPanel, forTypes: inTypes, completionHandler: completionHandler)
    }
}

/// Recently opened project folders, newest first (File ▸ Open Recent).
enum RecentFolders {
    private static let key = "recentFolders"

    static var list: [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func add(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: key)
    }
}

let app = NSApplication.shared
_ = KiteDocumentController()   // the first one made becomes NSDocumentController.shared
if DevTools.handle(CommandLine.arguments) { exit(0) }
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
