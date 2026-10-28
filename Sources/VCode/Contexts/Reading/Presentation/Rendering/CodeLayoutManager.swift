import AppKit

final class CodeLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    var kinds: [LineKind] = []
    var navigationRange: NSRange?
    var navigationAlpha: CGFloat = 0
    var symbolRanges: [NSRange] = []
    var searchRanges: [NSRange] = []
    var currentSearchRange: NSRange?
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
        func visible(_ ranges: [NSRange]) -> [NSRange] {
            ranges.filter { $0.location >= 0 && $0.length > 0 && $0.location <= (textStorage?.length ?? 0) &&
                $0.length <= (textStorage?.length ?? 0) - $0.location && NSIntersectionRange($0, visibleCharacters).length > 0 }
        }
        let searches = visible(searchRanges)
        let nativeSelections = (view as? CodeTextView)?.isFindSelection == true ? [] : visible(view.selectedRanges.map(\.rangeValue))
        let selectionRects = nativeSelections.flatMap { highlightRects($0, glyphsToShow: glyphsToShow, container: container, origin: origin) }
        let searchRects = searches.flatMap { highlightRects($0, glyphsToShow: glyphsToShow, container: container, origin: origin) }
        // Apply one semantic background per character. Search wins over symbol
        // feedback; native user selection wins over both, without mixed fills.
        for range in visible(symbolRanges) {
            for part in Self.uncovered(range, excluding: searches + nativeSelections) {
                drawHighlight(part, color: Theme.occurrence, alpha: 0.2, excluding: searchRects + selectionRects,
                              glyphsToShow: glyphsToShow, container: container, origin: origin)
            }
        }
        if let range = navigationRange, !visible([range]).isEmpty {
            for part in Self.uncovered(range, excluding: searches + nativeSelections) {
                drawHighlight(part, color: Theme.accent, alpha: navigationAlpha, excluding: searchRects + selectionRects,
                              glyphsToShow: glyphsToShow, container: container, origin: origin)
            }
        }
        for range in searches {
            guard !Self.uncovered(range, excluding: nativeSelections).isEmpty else { continue }
            let current = range == currentSearchRange
            drawHighlight(range, color: current ? Theme.currentSearchMatch : Theme.searchMatch,
                          alpha: current ? 0.3 : 0.16, bordered: current, excluding: selectionRects,
                          glyphsToShow: glyphsToShow, container: container, origin: origin)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    static func uncovered(_ range: NSRange, excluding exclusions: [NSRange]) -> [NSRange] {
        var parts = [range]
        for exclusion in exclusions {
            parts = parts.flatMap { part in
                let overlap = NSIntersectionRange(part, exclusion)
                guard overlap.length > 0 else { return [part] }
                var result: [NSRange] = []
                if overlap.location > part.location { result.append(NSRange(location: part.location, length: overlap.location - part.location)) }
                if NSMaxRange(overlap) < NSMaxRange(part) { result.append(NSRange(location: NSMaxRange(overlap), length: NSMaxRange(part) - NSMaxRange(overlap))) }
                return result
            }
            if parts.isEmpty { break }
        }
        return parts
    }

    private func highlightRects(_ range: NSRange, glyphsToShow: NSRange, container: NSTextContainer, origin: NSPoint, padding: CGFloat = 3) -> [NSRect] {
        let glyphs = NSIntersectionRange(glyphRange(forCharacterRange: range, actualCharacterRange: nil), glyphsToShow)
        guard glyphs.length > 0 else { return [] }
        var rects: [NSRect] = []
        enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -padding, dy: padding == 0 ? 0 : -1))
        }
        return rects
    }

    private func drawHighlight(_ range: NSRange, color: NSColor, alpha: CGFloat, bordered: Bool = false, excluding exclusions: [NSRect], glyphsToShow: NSRange, container: NSTextContainer, origin: NSPoint) {
        guard alpha > 0, let view = container.textView else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Clip exclusions separately, so intersecting search and selection holes
        // never cancel each other as they would in a single even-odd path.
        for exclusion in exclusions {
            let clip = NSBezierPath(rect: view.visibleRect.insetBy(dx: -4, dy: -2))
            clip.appendRect(exclusion)
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        for rect in highlightRects(range, glyphsToShow: glyphsToShow, container: container, origin: origin) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            color.withAlphaComponent(alpha).setFill()
            path.fill()
            if bordered {
                color.setStroke()
                let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                outline.lineWidth = 1
                outline.stroke()
            }
        }
    }
}
