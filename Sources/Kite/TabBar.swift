import AppKit

/// Kite's tabs: file names in small text. The active one is in full color, an unsaved file
/// gets a dot, and × appears on hover. No icons, borders or backgrounds.
@MainActor
final class TabBar: ChromeView {
    struct Item {
        let title: String
        let isActive: Bool
        let isDirty: Bool
    }

    var items: [Item] = [] { didSet { needsDisplay = true; invalidateIntrinsicContentSize() } }
    /// Space kept free on the left (for the window buttons when there's no sidebar).
    var leadingInset: CGFloat = 8 { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private var hovered: Int?
    private let padding: CGFloat = 14
    private let markWidth: CGFloat = 16   // room for "•" or "×", so tabs never change width

    override init(frame: NSRect) {
        super.init(frame: frame)
        hairlines = [.maxY]
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Open files")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Chrome.barHeight) }

    private struct Slot {
        let index: Int
        let frame: NSRect
        let mark: NSRect
    }

    /// Tabs that fit, plus how many are left over (shown as "+N").
    private func layoutSlots() -> (slots: [Slot], overflow: Int, overflowFrame: NSRect) {
        var slots: [Slot] = []
        var x = leadingInset
        let overflowWidth: CGFloat = 44
        for (i, item) in items.enumerated() {
            let textWidth = ceil((item.title as NSString).size(withAttributes: [.font: Chrome.font]).width)
            let width = padding + textWidth + 6 + markWidth + padding - 6
            let roomLeft = bounds.width - x - (i == items.count - 1 ? 0 : overflowWidth)
            if width > roomLeft && !slots.isEmpty { break }
            let frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            let mark = NSRect(x: frame.maxX - padding + 6 - markWidth, y: 0, width: markWidth, height: bounds.height)
            slots.append(Slot(index: i, frame: frame, mark: mark))
            x += width
        }
        let overflow = items.count - slots.count
        return (slots, overflow, NSRect(x: x, y: 0, width: overflowWidth, height: bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let (slots, overflow, overflowFrame) = layoutSlots()
        for slot in slots {
            let item = items[slot.index]
            let color = item.isActive ? Chrome.text : Chrome.dim
            let title = NSAttributedString(string: item.title, attributes: [.font: Chrome.font, .foregroundColor: color])
            let size = title.size()
            title.draw(at: NSPoint(x: slot.frame.minX + padding, y: (bounds.height - size.height) / 2))
            let mark = hovered == slot.index ? "×" : item.isDirty ? "•" : ""
            if !mark.isEmpty {
                let m = NSAttributedString(string: mark, attributes: [
                    .font: Chrome.font, .foregroundColor: hovered == slot.index ? Chrome.secondary : color,
                ])
                let ms = m.size()
                m.draw(at: NSPoint(x: slot.mark.midX - ms.width / 2, y: (bounds.height - ms.height) / 2))
            }
        }
        if overflow > 0 {
            let more = NSAttributedString(string: "+\(overflow)", attributes: [.font: Chrome.font, .foregroundColor: Chrome.dim])
            let size = more.size()
            more.draw(at: NSPoint(x: overflowFrame.minX + padding, y: (bounds.height - size.height) / 2))
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let index = layoutSlots().slots.first { $0.frame.contains(p) }?.index
        if index != hovered { hovered = index; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let (slots, overflow, overflowFrame) = layoutSlots()
        if let slot = slots.first(where: { $0.frame.contains(p) }) {
            if slot.mark.insetBy(dx: -4, dy: 0).contains(p) { onClose?(slot.index) } else { onSelect?(slot.index) }
            return
        }
        if overflow > 0, overflowFrame.contains(p) {
            showOverflowMenu(from: slots.count, at: NSPoint(x: overflowFrame.minX, y: overflowFrame.maxY))
            return
        }
        super.mouseDown(with: event)   // empty space drags the window
    }

    override func otherMouseDown(with event: NSEvent) {
        // Middle-click closes a tab, as in browsers.
        let p = convert(event.locationInWindow, from: nil)
        if let slot = layoutSlots().slots.first(where: { $0.frame.contains(p) }) { onClose?(slot.index) }
    }

    private func showOverflowMenu(from first: Int, at point: NSPoint) {
        let menu = NSMenu()
        for i in first..<items.count {
            let item = menu.addItem(withTitle: items[i].title + (items[i].isDirty ? " •" : ""), action: #selector(pickFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
        }
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func pickFromMenu(_ sender: NSMenuItem) { onSelect?(sender.tag) }
}
