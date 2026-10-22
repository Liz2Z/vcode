import AppKit

final class CodeLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var kinds: [LineKind] = []
    var navigationRange: NSRange?
    var navigationAlpha: CGFloat = 0
    var symbolRanges: [NSRange] = []
    var codeFont = Theme.Code.font()

    override init() {
        super.init()
        delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0 else { return false }
        // Fixed paragraph heights leave TextKit's extra space above the text.
        // Center the font's ascent/descent box inside the existing line instead;
        // glyph positions, selection, hit testing and underlines then agree.
        // NSTextStorage may replace a leading CJK character's font during font
        // fixing. Use the declared code font so fallback cannot shift the row.
        baselineOffset.pointee = Theme.Code.baseline(for: codeFont, lineHeight: lineFragmentRect.pointee.height)
        return true
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let container = textContainers.first, let view = container.textView else { super.drawBackground(forGlyphRange: glyphsToShow, at: origin); return }
        let first = max(0, Int((view.visibleRect.minY - Theme.Code.verticalInset) / Theme.Code.lineHeight))
        let last = min(kinds.count, first + Int(view.visibleRect.height / Theme.Code.lineHeight) + 4)
        if first < last {
            for index in first..<last {
                let color: NSColor?
                switch kinds[index] {
                case .added: color = Theme.added
                case .removed: color = Theme.removed
                case .placeholder: color = Theme.placeholder
                default: color = nil
                }
                if let color {
                    color.setFill()
                    NSRect(x: 0, y: CGFloat(index) * Theme.Code.lineHeight + origin.y, width: max(view.bounds.width, view.visibleRect.maxX), height: Theme.Code.lineHeight).fill()
                }
            }
        }
        let visibleCharacters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        for range in symbolRanges where range.length > 0 && NSMaxRange(range) <= (textStorage?.length ?? 0) && NSIntersectionRange(range, visibleCharacters).length > 0 {
            drawHighlight(range, alpha: 0.2, glyphsToShow: glyphsToShow, container: container, origin: origin)
        }
        if let range = navigationRange, range.length > 0, NSMaxRange(range) <= (textStorage?.length ?? 0) {
            drawHighlight(range, alpha: navigationAlpha, glyphsToShow: glyphsToShow, container: container, origin: origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    private func drawHighlight(_ range: NSRange, alpha: CGFloat, glyphsToShow: NSRange, container: NSTextContainer, origin: NSPoint) {
        guard alpha > 0 else { return }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        if NSIntersectionRange(glyphs, glyphsToShow).length > 0 {
            let rect = boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -3, dy: -1)
            Theme.accent.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }
}
