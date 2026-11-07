import AppKit
import Syntax

/// Editor colors for light or dark mode. Everything is a CGColor so Core Text can use it directly.
struct Theme {
    let background: CGColor
    let text: CGColor
    let currentLine: CGColor
    let selection: CGColor
    let inactiveSelection: CGColor
    let findMatch: CGColor
    let caret: CGColor
    let gutterText: CGColor
    let gutterCurrentText: CGColor
    let indentGuide: CGColor
    let bracketMatch: CGColor
    let tokens: [TokenKind: CGColor]
    let isDark: Bool

    /// The flat Kite theme by default; "Rainbow Colors" in the View menu brings back many token colors.
    static func forAppearance(_ appearance: NSAppearance) -> Theme {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if UserDefaults.standard.bool(forKey: "rainbowColors") { return dark ? .rainbowDark : .rainbowLight }
        return dark ? .dark : .light
    }

    /// Four flat colors on the text color: keywords, strings, numbers/constants, and dimmed comments.
    static let dark = Theme(
        background: hex(0x111214), text: hex(0xD6D8DC), currentLine: hex(0x111214),
        selection: hex(0x24324A), inactiveSelection: hex(0x1E2228), findMatch: hex(0x3B3324),
        caret: hex(0xE6E8EB), gutterText: hex(0x555A62), gutterCurrentText: hex(0xB4B8BE),
        indentGuide: CGColor(gray: 1, alpha: 0.05), bracketMatch: CGColor(gray: 1, alpha: 0.3),
        tokens: [
            .keyword: hex(0x8FA8D6), .tag: hex(0x8FA8D6),
            .string: hex(0xA6C48F), .escape: hex(0xA6C48F),
            .number: hex(0xD9A774), .constant: hex(0xD9A774),
            .comment: hex(0x7A7F87),
        ],
        isDark: true)

    static let light = Theme(
        background: hex(0xFAFAF9), text: hex(0x24262A), currentLine: hex(0xFAFAF9),
        selection: hex(0xD8E2F4), inactiveSelection: hex(0xE8EAEE), findMatch: hex(0xF3E3B5),
        caret: hex(0x24262A), gutterText: hex(0xA3A6AB), gutterCurrentText: hex(0x4B4F56),
        indentGuide: CGColor(gray: 0, alpha: 0.06), bracketMatch: CGColor(gray: 0, alpha: 0.3),
        tokens: [
            .keyword: hex(0x33589A), .tag: hex(0x33589A),
            .string: hex(0x4B7A3E), .escape: hex(0x4B7A3E),
            .number: hex(0xA25E14), .constant: hex(0xA25E14),
            .comment: hex(0x7D8189),
        ],
        isDark: false)

    /// The optional many-color theme, on Kite's own background so the window stays one surface.
    static let rainbowDark = Theme(
        background: hex(0x111214), text: hex(0xD5D8DE), currentLine: hex(0x111214),
        selection: hex(0x24324A), inactiveSelection: hex(0x1E2228), findMatch: hex(0x3B3324),
        caret: hex(0xE6E8EB), gutterText: hex(0x555A62), gutterCurrentText: hex(0xB4B8BE),
        indentGuide: CGColor(gray: 1, alpha: 0.05), bracketMatch: CGColor(gray: 1, alpha: 0.3),
        tokens: [
            .keyword: hex(0xC792EA), .string: hex(0xA5D38A), .escape: hex(0x6DCDD4),
            .comment: hex(0x6A7180), .number: hex(0xF0A86B), .constant: hex(0xF0A86B),
            .function: hex(0x7DB4FF), .builtin: hex(0x6DCDD4), .type: hex(0xF2CD7C),
            .property: hex(0xE59A9A), .parameter: hex(0xE6C9A8), .attribute: hex(0xF0A86B),
            .label: hex(0xE59A9A), .operator: hex(0x9EC6F0), .punctuation: hex(0x8D94A1),
            .tag: hex(0xE59A9A),
        ],
        isDark: true)

    static let rainbowLight = Theme(
        background: hex(0xFAFAF9), text: hex(0x24292F), currentLine: hex(0xFAFAF9),
        selection: hex(0xD8E2F4), inactiveSelection: hex(0xE8EAEE), findMatch: hex(0xF3E3B5),
        caret: hex(0x24262A), gutterText: hex(0xA3A6AB), gutterCurrentText: hex(0x4B4F56),
        indentGuide: CGColor(gray: 0, alpha: 0.06), bracketMatch: CGColor(gray: 0, alpha: 0.3),
        tokens: [
            .keyword: hex(0x9D2BB8), .string: hex(0x2F8A3A), .escape: hex(0x0E7C86),
            .comment: hex(0x8A919C), .number: hex(0xB05A00), .constant: hex(0xB05A00),
            .function: hex(0x2B63D9), .builtin: hex(0x0E7C86), .type: hex(0x9A6700),
            .property: hex(0xC2414B), .parameter: hex(0x7A4A1F), .attribute: hex(0xB05A00),
            .label: hex(0xC2414B), .operator: hex(0x3B4A5E), .punctuation: hex(0x6E7681),
            .tag: hex(0xC2414B),
        ],
        isDark: false)

    private static func hex(_ v: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
