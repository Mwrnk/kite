import AppKit
import Markdown

/// A read-only rendering of a Markdown document, drawn with Kite's colors. It sits beside the
/// editor and follows its scrolling through each block's source lines.
@MainActor
final class MarkdownPreview: NSView, NSTextViewDelegate {
    /// The Markdown file, for finding images and linked files next to it.
    var fileURL: URL?
    /// Follows the editor's text size.
    var fontSize: CGFloat = 13 {
        didSet { if fontSize != oldValue { render() } }
    }

    private let scrollView = NSScrollView()
    private let textView = NSTextView(usingTextLayoutManager: false)   // TextKit 1, for tables
    private var document = MarkdownDocument(blocks: [])
    /// Where each block starts in the text.
    private var blockStarts: [Int] = []
    /// Block tops in the text view, each worked out when first needed, for `topsWidth`.
    private var blockTops: [Int: CGFloat] = [:]
    private var topsWidth: CGFloat = 0
    /// What the current text was drawn with; anything else means drawing it all again.
    private var renderedWith: (fontSize: CGFloat, dark: Bool)?
    private var images: [URL: NSImage] = [:]
    private var theme: Theme = .dark

    init(fileURL: URL?) {
        self.fileURL = fileURL
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 400))

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 24, height: 18)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true   // lay out what's looked at, not the whole file
        textView.delegate = self

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Shows `document` in place of what was there, keeping the scroll position. Only the blocks
    /// that changed are drawn again, so an edit in a long file stays cheap.
    func show(_ document: MarkdownDocument) {
        let old = self.document.blocks
        let new = document.blocks
        self.document = document
        guard let storage = textView.textStorage, !old.isEmpty, blockStarts.count == old.count,
              renderedWith?.fontSize == fontSize, renderedWith?.dark == theme.isDark else {
            render()
            return
        }
        // Blocks that look the same; their source lines may have moved, which doesn't change the text.
        func same(_ a: MarkdownBlock, _ b: MarkdownBlock) -> Bool {
            a.kind == b.kind && a.spans == b.spans && a.quoteDepth == b.quoteDepth
                && a.listDepth == b.listDepth && a.marker == b.marker
        }
        var prefix = 0
        while prefix < old.count, prefix < new.count, same(old[prefix], new[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              same(old[old.count - 1 - suffix], new[new.count - 1 - suffix]) { suffix += 1 }
        blockTops = [:]
        if prefix == old.count && prefix == new.count { return }

        let start = prefix < old.count ? blockStarts[prefix] : storage.length
        let end = suffix > 0 ? blockStarts[old.count - suffix] : storage.length
        let (piece, starts) = renderer().render(new[prefix..<(new.count - suffix)])
        let clip = scrollView.contentView
        let scrollY = clip.bounds.origin.y
        storage.replaceCharacters(in: NSRange(location: start, length: end - start), with: piece)
        let delta = piece.length - (end - start)
        blockStarts = Array(blockStarts[..<prefix]) + starts.map { $0 + start }
            + blockStarts[(old.count - suffix)...].map { $0 + delta }
        clip.scroll(to: NSPoint(x: 0, y: min(scrollY, max(textView.frame.height - clip.bounds.height, 0))))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls so source `line`, plus `fraction` of a line, is at the top.
    func scroll(toLine line: Int, fraction: CGFloat) {
        let clip = scrollView.contentView
        let maxY = max(textView.frame.height - clip.bounds.height, 0)
        var y: CGFloat = 0
        if let index = document.blockIndex(forLine: line), index < blockStarts.count {
            let top = blockTop(index)
            let next = index + 1 < blockStarts.count ? blockTop(index + 1) : textView.frame.height
            let lines = document.blocks[index].lines
            let progress = (CGFloat(line - lines.lowerBound) + fraction) / CGFloat(lines.count)
            y = top + (next - top) * min(max(progress, 0), 1) - textView.textContainerInset.height
        }
        clip.scroll(to: NSPoint(x: 0, y: min(max(y, 0), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
        render()
    }

    // MARK: Drawing the document

    private func applyTheme() {
        theme = .forAppearance(effectiveAppearance)
        let background = color(theme.background)
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.selectedTextAttributes = [.backgroundColor: color(theme.selection)]
        textView.linkTextAttributes = [.foregroundColor: color(theme.tokens[.keyword] ?? theme.text),
                                       .cursor: NSCursor.pointingHand]
    }

    private func renderer() -> MarkdownRenderer {
        MarkdownRenderer(theme: theme, fontSize: fontSize, maxImageWidth: imageWidth,
                         image: { [weak self] source in self?.image(source) })
    }

    /// Draws the whole document again.
    private func render() {
        let clip = scrollView.contentView
        let scrollY = clip.bounds.origin.y
        let (text, starts) = renderer().render(document.blocks[...])
        textView.textStorage?.setAttributedString(text)
        blockStarts = starts
        blockTops = [:]
        renderedWith = (fontSize, theme.isDark)
        clip.scroll(to: NSPoint(x: 0, y: min(scrollY, max(textView.frame.height - clip.bounds.height, 0))))
        scrollView.reflectScrolledClipView(clip)
    }

    private var imageWidth: CGFloat {
        let width = scrollView.contentSize.width - textView.textContainerInset.width * 2
        return width > 50 ? width : 600
    }

    /// The top of block `index` in the text view. Lays out only as far as needed.
    private func blockTop(_ index: Int) -> CGFloat {
        if textView.frame.width != topsWidth { blockTops = [:]; topsWidth = textView.frame.width }
        if let top = blockTops[index] { return top }
        let origin = textView.textContainerOrigin.y
        guard let layout = textView.layoutManager, let container = textView.textContainer,
              let length = textView.textStorage?.length, length > 0 else { return origin }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: min(blockStarts[index], length - 1), length: 1),
                                       actualCharacterRange: nil)
        let top = layout.boundingRect(forGlyphRange: glyphs, in: container).minY + origin
        blockTops[index] = top
        return top
    }

    /// A file the document names by relative path, inside the project (or the file's folder) and
    /// reached without symbolic links. Anything else could make macOS connect to a network share
    /// just by looking at the path, and the preview never reaches the network.
    private func localFile(_ source: String) -> URL? {
        guard let folder = fileURL?.deletingLastPathComponent() else { return nil }
        let root = Project.containing(fileURL)?.root ?? folder
        guard let file = MarkdownPaths.localFile(source, folder: folder, root: root) else { return nil }
        // No symbolic links on the way from the root down (lstat only: a link is never followed).
        var step = root.standardizedFileURL
        for part in file.path.dropFirst(step.path.count).split(separator: "/") {
            step.appendPathComponent(String(part))
            if (try? step.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return nil }
        }
        return file
    }

    /// A local image, or nil for web images, missing files and anything `localFile` refuses.
    private func image(_ source: String) -> NSImage? {
        guard let url = localFile(source) else { return nil }
        if let cached = images[url] { return cached }
        // Only plain files of a sane size: /dev/zero or a pipe would hang the window.
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, (info.fileSize ?? 0) < 50_000_000,
              let image = NSImage(contentsOf: url) else { return nil }
        images[url] = image
        return image
    }

    // MARK: Links

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
        if let url = URL(string: target), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return true
        }
        // A file in the project: open it in Kite. Other schemes and paths are ignored.
        if let file = localFile(target), FileManager.default.fileExists(atPath: file.path) {
            NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
        }
        return true
    }
}

private func color(_ cg: CGColor) -> NSColor { NSColor(cgColor: cg) ?? .textColor }

/// Turns blocks into one attributed string, and notes where each block starts.
@MainActor
private struct MarkdownRenderer {
    let theme: Theme
    let fontSize: CGFloat
    let maxImageWidth: CGFloat
    let image: (String) -> NSImage?

    private var prose: NSFont { .systemFont(ofSize: fontSize + 1) }
    private var mono: NSFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    private var textColor: NSColor { color(theme.text) }
    private var dimColor: NSColor { color(theme.tokens[.comment] ?? theme.text) }
    private var boxColor: NSColor { color(theme.inactiveSelection) }

    private static let listStep: CGFloat = 22
    private static let quoteStep: CGFloat = 16

    /// Draws `blocks` and gives where each starts in the result.
    func render(_ blocks: ArraySlice<MarkdownBlock>) -> (NSAttributedString, [Int]) {
        let out = NSMutableAttributedString()
        var starts: [Int] = []
        var quoteBlocks: [NSTextBlock] = []   // one per open quote level, shared by its paragraphs
        for block in blocks {
            while quoteBlocks.count > block.quoteDepth { quoteBlocks.removeLast() }
            while quoteBlocks.count < block.quoteDepth { quoteBlocks.append(quoteBlock()) }
            starts.append(out.length)
            out.append(render(block, quotes: quoteBlocks))
        }
        return (out, starts)
    }

    private func render(_ block: MarkdownBlock, quotes: [NSTextBlock]) -> NSAttributedString {
        let indent = CGFloat(block.listDepth) * Self.listStep
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        style.paragraphSpacing = fontSize * 0.6
        style.firstLineHeadIndent = indent
        style.headIndent = indent
        style.textBlocks = quotes

        var font = prose
        var color = quotes.isEmpty ? textColor : dimColor

        switch block.kind {
        case .heading(let level):
            let scale: [CGFloat] = [1.9, 1.5, 1.25, 1.1, 1, 1]
            font = .systemFont(ofSize: (fontSize + 1) * scale[min(max(level, 1), 6) - 1], weight: .semibold)
            style.paragraphSpacingBefore = fontSize
            style.lineHeightMultiple = 1.15
            if quotes.isEmpty { color = textColor }

        case .paragraph:
            break

        case .codeBlock:
            let box = NSTextBlock()
            box.backgroundColor = boxColor
            box.setWidth(10, type: .absoluteValueType, for: .padding)
            box.setValue(100, type: .percentageValueType, for: .width)
            box.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
            box.setWidth(fontSize * 0.6, type: .absoluteValueType, for: .margin, edge: .maxY)
            style.textBlocks = quotes + [box]
            style.firstLineHeadIndent = 0
            style.headIndent = 0
            style.lineHeightMultiple = 1.2
            style.paragraphSpacing = 0
            let code = block.spans.map(\.text).joined()
            return NSAttributedString(string: code + "\n", attributes: [.font: mono, .foregroundColor: textColor, .paragraphStyle: style])

        case .table(let table):
            return render(table, indent: indent, quotes: quotes)

        case .rule:
            let line = NSTextBlock()
            line.setValue(100, type: .percentageValueType, for: .width)
            line.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
            line.setBorderColor(Chrome.hairline, for: .maxY)
            line.setWidth(fontSize * 0.6, type: .absoluteValueType, for: .margin, edge: .maxY)
            style.textBlocks = quotes + [line]
            style.lineHeightMultiple = 1
            style.paragraphSpacing = 0
            return NSAttributedString(string: " \n", attributes: [.font: NSFont.systemFont(ofSize: fontSize * 0.5), .paragraphStyle: style])
        }

        let out = NSMutableAttributedString()
        if let marker = block.marker {
            // The marker hangs in the indent; the text starts at the tab stop.
            let text: String = switch marker {
            case .bullet: "•"
            case .number(let n): "\(n)."
            case .task(let done): done ? "☑" : "☐"
            }
            style.firstLineHeadIndent = max(indent - Self.listStep + 4, 0)
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            style.paragraphSpacing = fontSize * 0.25   // list items sit closer than paragraphs
            out.append(NSAttributedString(string: text + "\t", attributes: [.font: prose, .foregroundColor: dimColor]))
        }
        out.append(inline(block.spans, font: font, color: color))
        out.append(NSAttributedString(string: "\n", attributes: [.font: font]))
        // Line spacing is a multiple of the tallest thing on the line, so an image would get a gap above it.
        if block.spans.contains(where: { $0.image != nil }) { style.lineHeightMultiple = 1 }
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return out
    }

    private func render(_ table: MarkdownTable, indent: CGFloat, quotes: [NSTextBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let columns = max(table.columns.count, ([table.header] + table.rows).map(\.count).max() ?? 1, 1)
        let grid = NSTextTable()
        grid.numberOfColumns = columns
        grid.collapsesBorders = true
        grid.hidesEmptyCells = false
        grid.setWidth(indent, type: .absoluteValueType, for: .margin, edge: .minX)
        grid.setWidth(fontSize * 0.8, type: .absoluteValueType, for: .margin, edge: .maxY)
        for (r, row) in ([table.header] + table.rows).enumerated() {
            for c in 0..<columns {
                let cell = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(Chrome.hairline)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                cell.setWidth(10, type: .absoluteValueType, for: .padding, edge: .maxX)
                let style = NSMutableParagraphStyle()
                style.textBlocks = quotes + [cell]
                style.alignment = switch c < table.columns.count ? table.columns[c] : .left {
                case .left: .left
                case .center: .center
                case .right: .right
                }
                let spans = c < row.count ? row[c] : []
                let font = r == 0 ? NSFont.systemFont(ofSize: fontSize + 1, weight: .semibold) : prose
                let text = NSMutableAttributedString(attributedString: inline(spans, font: font, color: textColor))
                text.append(NSAttributedString(string: "\n", attributes: [.font: font]))
                text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
                out.append(text)
            }
        }
        return out
    }

    private func inline(_ spans: [MarkdownSpan], font: NSFont, color: NSColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            if let source = span.image {
                out.append(imageText(source, alt: span.text, font: font))
                continue
            }
            var spanFont = font
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color]
            if span.style.contains(.code) {
                spanFont = .monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular)
                attributes[.backgroundColor] = boxColor
            }
            if span.style.contains(.strong) || span.style.contains(.emphasis) {
                spanFont = Self.styled(spanFont, bold: span.style.contains(.strong), italic: span.style.contains(.emphasis))
            }
            if span.style.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if span.style.contains(.html) { attributes[.foregroundColor] = dimColor }
            if let link = span.link { attributes[.link] = URL(string: link) ?? link as Any }
            attributes[.font] = spanFont
            out.append(NSAttributedString(string: span.text, attributes: attributes))
        }
        return out
    }

    private func imageText(_ source: String, alt: String, font: NSFont) -> NSAttributedString {
        guard let picture = image(source), picture.size.width > 0 else {
            return NSAttributedString(string: "[\(alt.isEmpty ? source : alt)]", attributes: [.font: font, .foregroundColor: dimColor])
        }
        let attachment = NSTextAttachment()
        attachment.image = picture
        let scale = min(1, maxImageWidth / picture.size.width)
        attachment.bounds = CGRect(x: 0, y: 0, width: picture.size.width * scale, height: picture.size.height * scale)
        return NSAttributedString(attachment: attachment)
    }

    /// Bold and italic versions of fonts, made once: converting a font is slow, and a long file has many spans.
    private static var styledFonts: [String: NSFont] = [:]

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let key = "\(font.fontName) \(font.pointSize) \(bold) \(italic)"
        if let cached = styledFonts[key] { return cached }
        var result = font
        if bold { result = NSFontManager.shared.convert(result, toHaveTrait: .boldFontMask) }
        if italic { result = NSFontManager.shared.convert(result, toHaveTrait: .italicFontMask) }
        styledFonts[key] = result
        return result
    }

    private func quoteBlock() -> NSTextBlock {
        let bar = NSTextBlock()
        bar.setValue(100, type: .percentageValueType, for: .width)   // without a width the block is ignored
        bar.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
        bar.setBorderColor(dimColor.withAlphaComponent(0.5), for: .minX)
        bar.setWidth(Self.quoteStep - 2, type: .absoluteValueType, for: .padding, edge: .minX)
        return bar
    }
}
