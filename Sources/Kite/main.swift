import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// True when last session's windows came back at launch.
    private var restoredSession = false

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
        if SessionStore.hasSession {
            restoredSession = SessionStore.restore()
            if !restoredSession && EditorWindowController.all.isEmpty { StartWindow.show() }
        }
        if ProcessInfo.processInfo.environment["KITE_LAUNCH_PROBE"] != nil { LaunchProbe.start() }
        if let script = ProcessInfo.processInfo.environment["KITE_TEST_SCRIPT"] { DevTools.runTestScript(script) }
        // Development aid: KITE_SNAPSHOT=/path.png saves the front window, as drawn, after 2.5 s.
        guard let path = ProcessInfo.processInfo.environment["KITE_SNAPSHOT"] else { return }
        guard ProcessInfo.processInfo.environment["KITE_TEST_SCRIPT"] == nil else { return }   // the script takes it
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                DevTools.snapshotFrontWindow(to: path)
                NSApp.terminate(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { SessionStore.save() }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if SessionStore.hasSession { return false }   // restored once launching finishes
        return !CommandLine.arguments.dropFirst().contains { !$0.hasPrefix("-") }
    }

    /// With nothing open, Kite starts on the recent folders and files instead of an empty file.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        StartWindow.show()
        return true
    }

    /// Clicking the Dock icon with no windows open brings the start window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { StartWindow.show() }
        return false
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

    /// Quitting doesn't ask about unsaved files: the session keeps their text and brings it back.
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                         didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        SessionStore.saveForQuitting()
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                                     didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
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
        // Scripted test runs don't belong in your recent folders.
        let env = ProcessInfo.processInfo.environment
        guard env["KITE_TEST_SCRIPT"] == nil, env["KITE_SESSION_DIR"] == nil, env["KITE_NO_SESSION"] == nil else { return }
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

/// For scripts/budget.sh: prints how long it took from process start until the first editor window
/// is on screen and ready for typing, then quits.
@MainActor
enum LaunchProbe {
    static func start() {
        // Poll each run-loop turn until an editor window is on screen (it may never become key when
        // started from a script, since another app is in front).
        poll()
    }

    private static func poll() {
        guard let window = EditorWindowController.all.first?.window, window.isVisible else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { MainActor.assumeIsolated { poll() } }
            return
        }
        window.displayIfNeeded()   // count the first full draw
        print(String(format: "launch_ms %.0f", (Date().timeIntervalSince1970 - processStart()) * 1000))
        exit(0)
    }

    static func processStart() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }
}
