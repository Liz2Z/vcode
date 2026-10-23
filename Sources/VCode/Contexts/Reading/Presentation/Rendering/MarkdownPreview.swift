import AppKit

final class MarkdownPreview: NSView, NSLayoutManagerDelegate {
    let scroll = NSScrollView()
    let text: NSTextView
    private(set) var isRendering = false
    private let queue = DispatchQueue(label: "dev.vcode.markdown", qos: .userInitiated)
    private var renderToken = UUID()
    private var sourceLines: [String] = []
    private var sourceOffsets: [Int] = []
    private var sourceSpans: [(rendered: NSRange, source: NSRange)] = []
    private var pendingPosition: MarkdownReadingPosition?
    private var resizing = false
    var onRendered: (() -> Void)?

    override init(frame frameRect: NSRect) {
        let layout = MarkdownLayoutManager()
        let storage = NSTextStorage()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        text = NSTextView(frame: .zero, textContainer: container)
        super.init(frame: frameRect)
        Theme.fill(self, Theme.background)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.textColor = Theme.text
        text.textContainerInset = NSSize(width: 28, height: 16)
        // This view owns container and document sizing. NSTextView's automatic
        // sizing must not replace the complete layout with a viewport-sized one.
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        text.autoresizingMask = []
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.usesFontLeading = false
        text.layoutManager?.delegate = self
        text.linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.setAccessibilityLabel("Markdown preview")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        Theme.compactScrollers(scroll)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        add(scroll)
        Theme.pin(scroll, to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ source: String, restoring position: MarkdownReadingPosition? = nil) {
        let token = UUID()
        renderToken = token
        pendingPosition = position
        isRendering = true
        queue.async { [weak self] in
            let value = Result { try MarkdownRenderer.render(source) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderToken == token else { return }
                switch value {
                case .success(let content): self.text.textStorage?.setAttributedString(content)
                case .failure: self.text.string = "Unable to preview this Markdown. Select Source to read the file."
                }
                self.sourceLines = source.components(separatedBy: "\n")
                var offset = 0
                self.sourceOffsets = self.sourceLines.map { line in defer { offset += (line as NSString).length + 1 }; return offset }
                self.sourceSpans = []
                self.text.textStorage?.enumerateAttribute(MarkdownRenderer.sourceRange, in: NSRange(location: 0, length: self.text.textStorage?.length ?? 0)) { value, range, _ in
                    if let span = value as? NSValue { self.sourceSpans.append((range, span.rangeValue)) }
                }
                // The history entry remains pending until visible layout is ready.
                self.layoutSubtreeIfNeeded()
                self.resizeText()
                self.applyPosition(self.pendingPosition)
                self.pendingPosition = nil
                self.isRendering = false
                self.onRendered?()
            }
        }
    }

    func clear() {
        renderToken = UUID(); isRendering = false; pendingPosition = nil
        sourceLines = []; sourceOffsets = []; sourceSpans = []
        text.string = ""
    }

    func readingPosition() -> MarkdownReadingPosition? {
        if isRendering { return pendingPosition }
        guard !sourceSpans.isEmpty, let layout = text.layoutManager, let container = text.textContainer else { return nil }
        layout.ensureLayout(for: container)
        let origin = scroll.contentView.bounds.origin
        let point = NSPoint(x: 0, y: max(0, origin.y - text.textContainerOrigin.y))
        let glyph = layout.glyphIndex(for: point, in: container)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let character = layout.characterIndexForGlyph(at: glyph)
        guard let span = sourceSpans.first(where: { NSMaxRange($0.rendered) > character }) ?? sourceSpans.last else { return nil }
        let mappedCharacter = min(max(character, span.rendered.location), NSMaxRange(span.rendered) - 1)
        let sourceOffset = span.source.location + (mappedCharacter - span.rendered.location) * span.source.length / max(1, span.rendered.length)
        let line = sourceOffsets.lastIndex(where: { $0 <= sourceOffset }) ?? 0
        let anchor = ReadingTextAnchor(line: line, character: sourceOffset - sourceOffsets[line], lines: sourceLines)
        let mappedGlyph = layout.glyphIndexForCharacter(at: mappedCharacter)
        let rect = layout.lineFragmentRect(forGlyphAt: mappedGlyph, effectiveRange: nil)
        return MarkdownReadingPosition(selection: text.selectedRange(), x: origin.x, y: origin.y, top: anchor,
            verticalOffset: origin.y - text.textContainerOrigin.y - rect.minY)
    }

    func restore(_ position: MarkdownReadingPosition?) {
        if isRendering { pendingPosition = position; return }
        resizeText()
        applyPosition(position)
    }

    private func applyPosition(_ position: MarkdownReadingPosition?) {
        let length = (text.string as NSString).length
        let start = min(position?.selection.location ?? 0, length)
        text.setSelectedRange(NSRange(location: start, length: min(position?.selection.length ?? 0, length - start)))
        var y = position?.y ?? 0
        if let anchor = position?.top, !sourceOffsets.isEmpty, let layout = text.layoutManager {
            let line = anchor.resolvedLine(in: sourceLines)
            let offset = sourceOffsets[line] + min(anchor.character, (sourceLines[line] as NSString).length)
            let span = sourceSpans.first(where: { NSLocationInRange(offset, $0.source) })
                ?? sourceSpans.min(by: { abs($0.source.location - offset) < abs($1.source.location - offset) })
            if let span {
                let sourceLength = max(1, span.source.length)
                let renderedOffset = (max(0, offset - span.source.location) * span.rendered.length + sourceLength - 1) / sourceLength
                let character = min(NSMaxRange(span.rendered) - 1, span.rendered.location + renderedOffset)
                let glyph = layout.glyphIndexForCharacter(at: character)
                y = text.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + (position?.verticalOffset ?? 0)
            }
        }
        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), max(0, text.bounds.height - clip.bounds.height))))
        scroll.reflectScrolledClipView(clip)
    }

    override func layout() {
        // Capture before changing width so reflow follows the same content.
        let position = isRendering ? nil : readingPosition()
        super.layout()
        resizeText()
        if let position { applyPosition(position) }
    }

    private func resizeText() {
        guard !resizing, let container = text.textContainer, let layout = text.layoutManager else { return }
        resizing = true
        defer { resizing = false }
        let width = max(80, scroll.contentSize.width)
        container.containerSize = NSSize(width: max(24, width - text.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        text.setFrameSize(NSSize(width: width, height: max(scroll.contentSize.height, ceil(layout.usedRect(for: container).height) + text.textContainerInset.height * 2)))
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard glyphRange.length > 0, let storage = layoutManager.textStorage else { return false }
        let index = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        guard index < storage.length, storage.attribute(MarkdownRenderer.codeBlock, at: index, effectiveRange: nil) as? Bool == true else { return false }
        baselineOffset.pointee = Theme.Code.baseline(for: Theme.Code.font(), lineHeight: lineFragmentRect.pointee.height)
        return true
    }
}

private final class MarkdownLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, container, glyphs, _ in
            guard glyphs.length > 0, let storage = self.textStorage else { return }
            let index = self.characterIndexForGlyph(at: glyphs.location)
            guard index < storage.length, storage.attribute(MarkdownRenderer.codeBlock, at: index, effectiveRange: nil) as? Bool == true else { return }
            Theme.surface.setFill()
            NSRect(x: origin.x + rect.minX, y: origin.y + rect.minY, width: min(rect.width, container.size.width), height: rect.height).fill()
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}
