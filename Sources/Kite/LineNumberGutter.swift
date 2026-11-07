import AppKit

/// The line-number gutter: a plain view to the left of the scroll view, so it never
/// overlaps the text and stays put when the text scrolls sideways.
final class LineNumberGutter: NSView {
    private weak var editorView: EditorView?
    private var widthConstraint: NSLayoutConstraint!

    init(editorView: EditorView) {
        self.editorView = editorView
        super.init(frame: .zero)
        clipsToBounds = true  // macOS 14+ no longer clips drawing to bounds by default
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 40)
        widthConstraint.isActive = true
        updateThickness()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    func updateThickness() {
        guard let editorView else { return }
        let digits = max(String(editorView.editor.buffer.lineCount).count, 3)
        let width = ceil(CGFloat(digits) * editorView.charWidth + 24)
        if widthConstraint.constant != width { widthConstraint.constant = width }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let editorView, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let theme = editorView.theme
        ctx.setFillColor(theme.background)
        ctx.fill(dirtyRect)

        let buffer = editorView.editor.buffer
        let currentLine = buffer.line(containing: editorView.editor.caret)
        let font = NSFont.monospacedDigitSystemFont(ofSize: editorView.font.pointSize - 1, weight: .regular)
        let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: theme.gutterText)!]
        let current: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: theme.gutterCurrentText)!]

        for line in editorView.visibleLines {
            let label = NSAttributedString(string: String(line + 1), attributes: line == currentLine ? current : normal)
            let size = label.size()
            let top = convert(NSPoint(x: 0, y: editorView.lineTop(line)), from: editorView).y
            label.draw(at: NSPoint(x: bounds.width - size.width - 10, y: top + (editorView.lineHeight - size.height) / 2))
        }
    }
}
