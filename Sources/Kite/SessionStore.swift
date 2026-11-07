import AppKit
import EditorCore

/// Remembers what's open so Kite can quit without asking and come back exactly as it was:
/// each window's folder, size, tabs, cursors and scroll positions, plus unsaved edits, which
/// are kept as backup files until you save or close them.
///
/// Saved when Kite quits and a few seconds after changes (so a crash loses little).
/// Set KITE_NO_SESSION=1 to neither restore nor save (scripts and tests).
@MainActor
enum SessionStore {
    struct Session: Codable {
        var windows: [WindowState]
    }

    struct WindowState: Codable {
        var project: String?
        var frame: String
        var fileListHidden: Bool
        var active: Int
        var tabs: [TabState]
    }

    struct TabState: Codable {
        /// Nil for an untitled file (its text is in the backup).
        var path: String?
        var anchor: Int
        var head: Int
        /// More cursors, as [anchor, head] pairs.
        var extra: [[Int]]?
        var scrollY: Double
        /// Backup file holding unsaved text, if the tab had any.
        var backup: String?
    }

    static var isEnabled: Bool { ProcessInfo.processInfo.environment["KITE_NO_SESSION"] == nil }

    /// Set once Kite has saved for quitting; later saves would see already-cleared documents.
    static var isQuitting = false

    /// ~/Library/Application Support/Kite, or KITE_SESSION_DIR (for tests).
    static var directory: URL = ProcessInfo.processInfo.environment["KITE_SESSION_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kite", isDirectory: true)
    static var sessionURL: URL { directory.appendingPathComponent("session.json") }
    static var backupsURL: URL { directory.appendingPathComponent("backups", isDirectory: true) }

    // MARK: Saving

    static func save() {
        guard isEnabled, !isQuitting else { return }
        pending?.cancel()
        let fm = FileManager.default
        try? fm.createDirectory(at: backupsURL, withIntermediateDirectories: true)
        var used = Set<String>()
        // Back to front, so the front window is restored last and ends up in front again.
        let windows = EditorWindowController.all.reversed().compactMap {
            $0.sessionState(backupsIn: backupsURL, used: &used)
        }
        if let data = try? JSONEncoder().encode(Session(windows: windows)) {
            try? data.write(to: sessionURL, options: .atomic)
        }
        // Drop backups nothing refers to any more (saved or closed files).
        let files = (try? fm.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil)) ?? []
        for file in files where !used.contains(file.lastPathComponent) { try? fm.removeItem(at: file) }
    }

    private static var pending: DispatchWorkItem?

    /// Saves a few seconds after the last change.
    static func scheduleSave() {
        guard isEnabled, !isQuitting else { return }
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { save() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    /// Saves for quitting, then marks every document clean so macOS doesn't ask to save:
    /// their unsaved text is safe in the backups and comes back next launch.
    static func saveForQuitting() {
        guard isEnabled else { return }
        save()
        isQuitting = true
        for case let doc as TextDocument in NSDocumentController.shared.documents where doc.isDocumentEdited {
            doc.updateChangeCount(.changeCleared)
        }
    }

    // MARK: Restoring

    /// True if there's a saved session that may have windows to bring back.
    static var hasSession: Bool {
        guard isEnabled, let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        return !session.windows.isEmpty
    }

    /// Reopens the last session's windows. Returns true if any window came back.
    @discardableResult
    static func restore() -> Bool {
        guard isEnabled, let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(Session.self, from: data) else { return false }
        var restored = false
        for window in session.windows where EditorWindowController.restore(window, backupsIn: backupsURL) {
            restored = true
        }
        return restored
    }
}
