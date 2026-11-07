import AppKit

/// Kite's own window look: one background, 1 px hairlines, and text instead of icons.
/// Colors resolve for light or dark mode when drawn.
@MainActor
enum Chrome {
    static let background = color(0x111214, 0xFAFAF9)
    /// Text in full strength: the active tab, the open file.
    static let text = color(0xD6D8DC, 0x24262A)
    static let bright = color(0xE6E8EB, 0x111214)
    /// File names and other secondary text.
    static let secondary = color(0x9DA1A8, 0x4B4F56)
    /// Chrome labels: inactive tabs, the status line.
    static let dim = color(0x7E838B, 0x6B6F76)
    static let faint = color(0x6E737B, 0x8A8D93)
    static let hairline = color(0x222428, 0xE7E7E4)
    /// The only raised surface, for overlays like quick open.
    static let raised = color(0x17181B, 0xFFFFFF)
    static let raisedLine = color(0x2A2C31, 0xE2E2DE)
    static let match = color(0x24324A, 0xD8E2F4)
    static let modified = color(0xD9A774, 0xA25E14)
    static let added = color(0xA6C48F, 0x4B7A3E)
    static let error = color(0xE07B7B, 0xB54A4A)

    /// Tabs, status line and other chrome.
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    /// The file list.
    static let fileFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static let barHeight: CGFloat = 38
    static let statusHeight: CGFloat = 28

    private static func color(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    /// A label in the chrome font.
    static func label(_ text: String = "", color: NSColor = Chrome.dim) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    /// A borderless button that is only a word ("Aa", "files", "↑").
    static func textButton(_ title: String, target: AnyObject?, action: Selector?) -> TextButton {
        let button = TextButton(title: title, target: target, action: action)
        return button
    }
}

/// A plain area painted with the window background (redrawn when light/dark changes).
@MainActor
class ChromeView: NSView {
    var fill: NSColor = Chrome.background { didSet { needsDisplay = true } }
    /// Draws a 1 px hairline along these edges.
    var hairlines: NSRectEdge.Set = [] { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true   // macOS 14+ lets views draw outside their bounds unless told not to
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        // Only ever paint inside this view: the area to redraw can extend past it.
        dirtyRect.intersection(bounds).fill(using: .sourceOver)
        Chrome.hairline.setFill()
        let scale = window?.backingScaleFactor ?? 2
        let w = 1 / scale
        if hairlines.contains(.minY) { NSRect(x: 0, y: 0, width: bounds.width, height: w).fill(using: .sourceOver) }
        if hairlines.contains(.maxY) { NSRect(x: 0, y: bounds.height - w, width: bounds.width, height: w).fill(using: .sourceOver) }
        if hairlines.contains(.minX) { NSRect(x: 0, y: 0, width: w, height: bounds.height).fill(using: .sourceOver) }
        if hairlines.contains(.maxX) { NSRect(x: bounds.width - w, y: 0, width: w, height: bounds.height).fill(using: .sourceOver) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Empty chrome drags the window, since there's no title bar to grab.
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

extension NSRectEdge {
    /// Which edges of a view get a hairline.
    struct Set: OptionSet {
        let rawValue: Int
        static let minY = Set(rawValue: 1), maxY = Set(rawValue: 2), minX = Set(rawValue: 4), maxX = Set(rawValue: 8)
    }
}

/// A word that acts as a button. Lit (full text color) when `isOn`, dim otherwise.
@MainActor
final class TextButton: NSButton {
    var isOn = false { didSet { restyle() } }

    convenience init(title: String, target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        restyle()
    }

    private func restyle() {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Chrome.font, .foregroundColor: isOn ? Chrome.text : Chrome.dim,
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// A split view whose divider is a 1 px hairline.
final class HairlineSplitView: NSSplitView {
    override var dividerColor: NSColor { Chrome.hairline }
    override var dividerThickness: CGFloat { 1 }

    override func drawDivider(in rect: NSRect) {
        Chrome.hairline.setFill()
        rect.fill()
    }
}
