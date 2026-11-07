import AppKit
import EditorCore
import Syntax
import UniformTypeIdentifiers

/// One open file. NSDocument gives us open/save panels, the unsaved dot,
/// "save changes?" prompts, window tabs and recent files.
@objc(TextDocument)
final class TextDocument: NSDocument {
    private(set) var editor = TextEditor()
    private(set) var format = FileFormat()

    override init() {
        super.init()
        hasUndoManager = false  // TextEditor keeps its own undo history
    }

    override class var autosavesInPlace: Bool { false }
    override nonisolated class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }

    var language: Language? {
        fileURL.flatMap { Language.forFileExtension($0.pathExtension) }
    }

    /// Opens as a tab in its project's window (or the front window); only a document with
    /// nowhere to go gets a window of its own.
    override func makeWindowControllers() {
        if let window = EditorWindowController.windowForNewDocument(self) {
            window.addTab(for: self)
        } else {
            addWindowController(EditorWindowController(document: self))
        }
    }

    /// Bringing an open document forward means selecting its tab.
    override func showWindows() {
        if let window = EditorWindowController.controller(containing: self) {
            window.activate(document: self)
            window.showWindow(nil)
        } else {
            super.showWindows()
        }
    }

    // Reads always happen on the main thread (concurrent reading is off above).
    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        let (text, format) = TextFileCodec.decode(data)
        MainActor.assumeIsolated { load(text, format) }
    }

    private func load(_ text: String, _ format: FileFormat) {
        self.format = format
        if EditorWindowController.controller(containing: self) == nil && windowControllers.isEmpty {
            editor = TextEditor(buffer: TextBuffer(text))
        } else {
            // Revert: the window keeps its editor, so reload the text into it.
            editor.resetText(text)
            updateChangeCount(.changeCleared)
        }
        // Match the file's indentation style if it clearly uses tabs.
        let firstIndented = text.split(separator: "\n", maxSplits: 2000).first { $0.first == "\t" || $0.hasPrefix("  ") }
        editor.settings.insertSpaces = firstIndented?.first != "\t"
    }

    override func data(ofType typeName: String) throws -> Data {
        try TextFileCodec.encode(editor.text, format: format)
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping ((any Error)?) -> Void) {
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil, saveOperation != .saveToOperation {
                self?.editor.markSaved()
                self?.updateChangeCount(.changeCleared)
                if let self { EditorWindowController.controller(containing: self)?.documentDidSave(self) }
            }
            completionHandler(error)
        }
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowsOtherFileTypes = true
        savePanel.isExtensionHidden = false
        savePanel.allowedContentTypes = []
        return true
    }

    /// Keeps the window's unsaved-changes dot in sync with the editor's undo position.
    func editorTextDidChange() {
        updateChangeCount(editor.isDirty ? .changeDone : .changeCleared)
    }
}
