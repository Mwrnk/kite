import AppKit
import EditorCore

/// Carries out a Replace in Files the user previewed in project search.
///
/// Every file is searched again first. If its matches aren't the ones that were previewed (it
/// changed since), it is left alone and reported. Up to `maxTabs` files are edited in memory
/// and open as unsaved background tabs, one undo step each; File ▸ Save All saves them. Past
/// that, Kite asks once and saves straight to disk, keeping the originals so
/// Edit ▸ Undo Replace in Files can put them back.
@MainActor
enum ProjectReplace {
    struct FilePlan: Sendable {
        let url: URL
        /// Where every previewed match started, skipped ones included.
        let previewed: [Int]
        /// Matches the user skipped, by where they start.
        let skip: Set<Int>
    }

    /// A file the last replace saved to disk.
    struct Saved {
        let url: URL
        let original: Data
        let written: Data
    }

    static let maxTabs = 20
    /// Files saved by the last replace that went straight to disk.
    private(set) static var lastSaved: [Saved] = []

    /// How files are matched up (paths can differ by symlinks, like /tmp and /private/tmp).
    nonisolated static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    /// The text of every file open in Kite, by `key`.
    static func openTexts() -> [String: String] {
        var texts: [String: String] = [:]
        for case let doc as TextDocument in NSDocumentController.shared.documents {
            if let url = doc.fileURL { texts[key(url)] = doc.editor.text }
        }
        return texts
    }

    private static func openDocument(_ url: URL) -> TextDocument? {
        let k = key(url)
        return NSDocumentController.shared.documents.lazy
            .compactMap { $0 as? TextDocument }
            .first { $0.fileURL.map(key) == k }
    }

    /// What one file becomes, worked out in the background.
    private struct Outcome: Sendable {
        let plan: FilePlan
        /// The text the edits were worked out on.
        let text: String
        let edits: [(range: Range<Int>, text: String)]
        /// Disk files only: the bytes read, and (when saving straight to disk) the bytes to write.
        let original: Data?
        let replacement: Data?
        /// The file's matches weren't the previewed ones.
        let changed: Bool
    }

    /// Replaces in `plans`, then calls `done` with a one-line report.
    static func apply(_ plans: [FilePlan], query: FindQuery, template: String,
                      in controller: EditorWindowController, done: @escaping @MainActor (String) -> Void) {
        guard plans.count > maxTabs else {
            run(plans, query: query, template: template, saving: false, in: controller, done: done)
            return
        }
        let total = plans.reduce(0) { $0 + $1.previewed.count - $1.skip.count }
        let alert = NSAlert()
        alert.messageText = "Replace \(total) in \(plans.count) files and save them?"
        alert.informativeText = "That's too many to open as tabs, so the files are saved right away. "
            + "Edit ▸ Undo Replace in Files puts them back. Files already open in Kite are changed in their tabs and left unsaved."
        alert.addButton(withTitle: "Replace and Save")
        alert.addButton(withTitle: "Cancel")
        guard let window = controller.window else { return }
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                run(plans, query: query, template: template, saving: true, in: controller, done: done)
            }
        }
    }

    static func run(_ plans: [FilePlan], query: FindQuery, template: String, saving: Bool,
                            in controller: EditorWindowController, done: @escaping @MainActor (String) -> Void) {
        let open = openTexts()
        Task.detached(priority: .userInitiated) {
            var outcomes: [Outcome] = []
            for plan in plans {
                var text: String
                var original: Data?
                var format = FileFormat()
                if let onScreen = open[key(plan.url)] {
                    text = onScreen
                } else {
                    guard let data = try? Data(contentsOf: plan.url) else {
                        outcomes.append(Outcome(plan: plan, text: "", edits: [], original: nil, replacement: nil, changed: true))
                        continue
                    }
                    (text, format) = TextFileCodec.decode(data)
                    original = data
                }
                let all = query.replacements(in: text, template: template)
                let changed = all.map(\.range.lowerBound) != plan.previewed
                let edits = changed ? [] : all.filter { !plan.skip.contains($0.range.lowerBound) }
                var replacement: Data?
                if saving, original != nil, !changed {
                    var bytes = Array(text.utf8)
                    for edit in edits.reversed() { bytes.replaceSubrange(edit.range, with: Array(edit.text.utf8)) }
                    replacement = try? TextFileCodec.encode(String(decoding: bytes, as: UTF8.self), format: format)
                }
                outcomes.append(Outcome(plan: plan, text: text, edits: edits, original: original,
                                        replacement: replacement, changed: changed))
            }
            await MainActor.run { finish(outcomes, saving: saving, in: controller, done: done) }
        }
    }

    private static func finish(_ outcomes: [Outcome], saving: Bool, in controller: EditorWindowController,
                               done: @MainActor (String) -> Void) {
        var replaced = 0, files = 0, changed = 0, leftUnsaved = 0
        var saved: [Saved] = []
        for outcome in outcomes {
            if outcome.changed { changed += 1; continue }
            guard !outcome.edits.isEmpty else { continue }
            let url = outcome.plan.url

            if outcome.original == nil {
                // Open in Kite: edit it in its tab, if it hasn't changed since.
                guard let doc = openDocument(url), doc.editor.text == outcome.text else { changed += 1; continue }
                doc.editor.replace(outcome.edits)
                doc.editorTextDidChange()
                if saving { leftUnsaved += 1 }
            } else if saving {
                // Straight to disk, if the file is still what was read.
                guard let original = outcome.original, let data = outcome.replacement,
                      (try? Data(contentsOf: url)) == original,
                      (try? data.write(to: url, options: .atomic)) != nil else { changed += 1; continue }
                saved.append(Saved(url: url, original: original, written: data))
            } else {
                // Open it as an unsaved background tab.
                guard let doc = try? TextDocument(contentsOf: url, ofType: "Text"), doc.editor.text == outcome.text else {
                    changed += 1; continue
                }
                NSDocumentController.shared.addDocument(doc)
                doc.editor.replace(outcome.edits)
                doc.editorTextDidChange()
                controller.addTab(for: doc, activate: false)
            }
            replaced += outcome.edits.count
            files += 1
        }
        if saving { lastSaved = saved }
        // Tabs that aren't in front don't hear about edits made to them; show their unsaved dots.
        EditorWindowController.all.forEach { $0.refreshTabs() }
        SessionStore.scheduleSave()

        var report = replaced == 0 ? "Nothing replaced" : "Replaced \(replaced) in \(files) file\(files == 1 ? "" : "s")"
        if !saving && files > 0 { report += ", unsaved (⌥⌘S saves all)" }
        if saving && !saved.isEmpty { report += ", saved" }
        if leftUnsaved > 0 { report += "; \(leftUnsaved) open file\(leftUnsaved == 1 ? "" : "s") left unsaved" }
        if changed > 0 { report += "; \(changed) file\(changed == 1 ? "" : "s") changed since the search, left alone" }
        done(report)
    }

    /// Puts back the files the last straight-to-disk replace saved, unless they changed since.
    static func undoLast() -> String {
        var restored = 0, skipped = 0
        for entry in lastSaved {
            guard (try? Data(contentsOf: entry.url)) == entry.written,
                  (try? entry.original.write(to: entry.url, options: .atomic)) != nil else { skipped += 1; continue }
            restored += 1
            // A tab showing the file with no edits of its own reloads it.
            if let doc = openDocument(entry.url), !doc.isDocumentEdited, let type = doc.fileType {
                try? doc.revert(toContentsOf: entry.url, ofType: type)
            }
        }
        lastSaved = []
        var report = "Put back \(restored) file\(restored == 1 ? "" : "s")"
        if skipped > 0 { report += "; \(skipped) changed since, left alone" }
        return report
    }
}
