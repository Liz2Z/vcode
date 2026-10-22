import AppKit

final class MarkdownPreview: NSView, NSLayoutManagerDelegate {
    let scroll = NSScrollView()
    let text: NSTextView
    private(set) var isRendering = false
    private let queue = DispatchQueue(label: "dev.vcode.markdown", qos: .userInitiated)
    private var renderToken = UUID()

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
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        text.layoutManager?.usesFontLeading = false
        text.layoutManager?.delegate = self
        text.linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.setAccessibilityLabel("Markdown preview")
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        add(scroll)
        Theme.pin(scroll, to: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ source: String) {
        let token = UUID()
        renderToken = token
        isRendering = true
        text.string = "Rendering Markdown…"
        queue.async { [weak self] in
            let value = Result { try MarkdownRenderer.render(source) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.renderToken == token else { return }
                self.isRendering = false
                switch value {
                case .success(let content): self.text.textStorage?.setAttributedString(content)
                case .failure: self.text.string = "Unable to preview this Markdown. Select Source to read the file."
                }
                self.text.setSelectedRange(NSRange(location: 0, length: 0))
                self.resizeText()
                self.scroll.contentView.scroll(to: .zero)
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
        }
    }

    func clear() { renderToken = UUID(); isRendering = false; text.string = "" }

    override func layout() { super.layout(); resizeText() }

    private func resizeText() {
        let width = max(80, scroll.contentSize.width)
        text.frame.size.width = width
        guard let container = text.textContainer, let layout = text.layoutManager else { return }
        container.containerSize.width = max(24, width - text.textContainerInset.width * 2)
        layout.ensureLayout(for: container)
        text.frame.size.height = max(scroll.contentSize.height, ceil(layout.usedRect(for: container).height) + text.textContainerInset.height * 2)
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
