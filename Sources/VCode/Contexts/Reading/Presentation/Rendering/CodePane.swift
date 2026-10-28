import AppKit

final class CodePane: NSView {
    let scroll = NSScrollView()
    let text: CodeTextView
    let gutter: CodeGutter
    let diffOverview = DiffOverview()
    private var overviewWidth: NSLayoutConstraint!
    private var overviewSpacing: [NSLayoutConstraint] = []
    private let codeLayout: CodeLayoutManager
    private let caption = Theme.label("", size: 11, color: Theme.muted)
    private let badge = Theme.label("", size: 11, color: Theme.muted)
    private let header = NSView()
    private var headerHeight: NSLayoutConstraint!
    private var observation: NSObjectProtocol?
    private var documentObservation: NSObjectProtocol?
    private(set) var lines: [CodeLine] = []
    private(set) var offsets: [Int] = []
    var onScroll: ((NSPoint) -> Void)?
    var onWillReplaceText: (() -> Void)?
    var onSearchMatchesChanged: (() -> Void)?
    var additionalSearchRows: [Int] = [] { didSet { updateOccurrenceMarkers() } }
    var additionalCurrentSearchRows: [Int] = [] { didSet { updateOccurrenceMarkers() } }
    var isSyncing = false

    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = CodeLayoutManager()
        layout.usesFontLeading = false
        let container = NSTextContainer(size: NSSize(width: 10_000_000, height: 10_000_000))
        container.widthTracksTextView = false
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        codeLayout = layout
        text = CodeTextView(frame: .zero, textContainer: container)
        gutter = CodeGutter(scroll: scroll, text: text)
        super.init(frame: frameRect)
        Theme.fill(self, Theme.background)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isContinuousSpellCheckingEnabled = false
        text.backgroundColor = Theme.background
        text.textColor = Theme.text
        text.insertionPointColor = Theme.text
        text.font = Theme.Code.font()
        text.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        text.textContainerInset = NSSize(width: 10, height: Theme.Code.verticalInset)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = true
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        Theme.compactScrollers(scroll)
        // Legacy corner views are inserted when both scrollers appear. During
        // a checkout relayout AppKit can reject their new constraints.
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.clipsToBounds = true
        scroll.backgroundColor = Theme.background
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        text.postsFrameChangedNotifications = true
        documentObservation = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: text, queue: .main) { [weak self] _ in
            self?.updateOverview()
        }
        observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.text.cancelInspection()
            self.gutter.needsDisplay = true
            self.text.needsDisplay = true
            self.updateOverview()
            if !self.isSyncing { self.onScroll?(self.scroll.contentView.bounds.origin) }
        }
        Theme.fill(header, Theme.background)
        header.add(caption, badge)
        add(header, scroll, diffOverview)
        diffOverview.isHidden = true
        overviewWidth = diffOverview.widthAnchor.constraint(equalToConstant: 0)
        overviewSpacing = [
            diffOverview.leadingAnchor.constraint(equalTo: scroll.trailingAnchor),
            diffOverview.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffOverview.topAnchor.constraint(equalTo: scroll.topAnchor),
            diffOverview.bottomAnchor.constraint(equalTo: scroll.bottomAnchor)
        ]
        diffOverview.onNavigate = { [weak self] y in
            guard let self else { return }
            self.scrollTo(NSPoint(x: self.scroll.contentView.bounds.minX, y: y))
            self.onScroll?(self.scroll.contentView.bounds.origin)
            self.updateOverview()
        }
        diffOverview.onWheel = { [weak self] event in self?.scroll.scrollWheel(with: event) }
        text.onOccurrencesChanged = { [weak self] _ in
            guard let self else { return }
            self.updateOccurrenceMarkers()
        }
        headerHeight = header.heightAnchor.constraint(equalToConstant: 28)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), headerHeight,
            caption.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: Theme.Layout.inset), caption.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -Theme.Layout.inset), badge.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor), scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor), overviewWidth
        ] + overviewSpacing)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        if let documentObservation { NotificationCenter.default.removeObserver(documentObservation) }
    }

    func showDiffOverview(_ rows: [DiffRow]?, source: Bool = false) {
        diffOverview.isHidden = rows == nil && !source
        overviewWidth.constant = diffOverview.isHidden ? 0 : DiffOverview.preferredWidth
        let inset = diffOverview.isHidden ? 0 : DiffOverview.outerInset
        for (constraint, constant) in zip(overviewSpacing, [inset, -inset, inset, -inset]) { constraint.constant = constant }
        scroll.hasVerticalScroller = diffOverview.isHidden
        Theme.compactScrollers(scroll)
        diffOverview.show(rows: rows ?? [], isDiff: rows != nil)
        updateOverview()
    }

    override func layout() { super.layout(); updateOverview() }

    private func updateOverview() {
        guard !diffOverview.isHidden else { return }
        diffOverview.update(documentHeight: text.bounds.height, visibleHeight: scroll.contentView.bounds.height,
                            scrollY: scroll.contentView.bounds.minY)
    }

    func setSearchMatches(_ ranges: [NSRange]) {
        text.setSearchMatches(ranges)
        updateOccurrenceMarkers()
        onSearchMatchesChanged?()
    }

    func setCurrentSearchMatch(_ range: NSRange?) {
        text.setCurrentSearchMatch(range)
        updateOccurrenceMarkers()
        onSearchMatchesChanged?()
    }

    func overviewRows(for ranges: [NSRange]) -> [Int] {
        // UTF-16 ranges already include diff placeholders. Do not create glyph
        // layout for offscreen matches just to put them in the overview.
        func row(at index: Int) -> Int {
            var low = 0, high = offsets.count
            while low < high {
                let middle = (low + high) / 2
                if offsets[middle] <= index { low = middle + 1 } else { high = middle }
            }
            return max(0, low - 1)
        }
        return ranges.flatMap { range -> [Int] in
            guard !offsets.isEmpty, range.length > 0 else { return [] }
            return Array(row(at: range.location)...row(at: NSMaxRange(range) - 1))
        }
    }

    private func updateOccurrenceMarkers() {
        diffOverview.showOccurrences(rows: overviewRows(for: text.occurrenceRanges))
        diffOverview.showSearch(rows: overviewRows(for: text.searchRanges) + additionalSearchRows,
                                currentRows: overviewRows(for: text.currentSearchRange.map { [$0] } ?? []) + additionalCurrentSearchRows)
    }

    func show(lines: [CodeLine], path: String, title: String, detail: String, showsHeader: Bool = true) {
        onWillReplaceText?()
        setSearchMatches([])
        text.isEditable = false
        text.supportsCodeIntelligence = true
        text.undoManager?.removeAllActions()
        text.cancelNavigationFlash()
        text.resetSymbolFeedback()
        text.cancelInspection()
        header.isHidden = !showsHeader
        headerHeight.constant = showsHeader ? 28 : 0
        self.lines = lines
        caption.stringValue = title
        badge.stringValue = detail
        gutter.lines = lines
        codeLayout.kinds = lines.map(\.kind)
        var offset = 0
        offsets = lines.map { line in defer { offset += (line.text as NSString).length + 1 }; return offset }
        text.string = lines.isEmpty ? "" : lines.map(\.text).joined(separator: "\n") + "\n"
        text.setSelectedRange(NSRange(location: 0, length: 0))
        if let storage = text.textStorage {
            Syntax.apply(to: storage, path: path, font: Theme.Code.font())
        }
        gutter.needsDisplay = true
        text.needsDisplay = true
    }

    func showEditable(_ source: String, path: String) {
        show(lines: [], path: path, title: "", detail: "", showsHeader: false)
        text.string = source
        text.isEditable = true
        text.supportsCodeIntelligence = false
        text.allowsUndo = true
        updateEditableLines(path: path)
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Theme.Code.lineHeight
        paragraph.maximumLineHeight = Theme.Code.lineHeight
        paragraph.defaultTabInterval = max(7, Theme.Code.font().maximumAdvancement.width) * 4
        paragraph.tabStops = []
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: Theme.Code.font(), .foregroundColor: Theme.text, .paragraphStyle: paragraph]
        text.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func updateEditableLines(path: String, allowReadOnly: Bool = false) {
        guard text.isEditable || allowReadOnly else { return }
        lines = text.string.components(separatedBy: "\n").enumerated().map {
            CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged)
        }
        var offset = 0
        offsets = lines.map { line in defer { offset += (line.text as NSString).length + 1 }; return offset }
        gutter.lines = lines
        codeLayout.kinds = lines.map(\.kind)
        let undo = text.undoManager
        undo?.disableUndoRegistration()
        if let storage = text.textStorage { Syntax.apply(to: storage, path: path, font: Theme.Code.font()) }
        undo?.enableUndoRegistration()
        gutter.needsDisplay = true
    }

    func resetScroll() {
        layoutSubtreeIfNeeded()
        let insets = scroll.contentView.contentInsets
        scrollTo(NSPoint(x: -insets.left, y: -insets.top))
    }

    private func scrollTo(_ point: NSPoint) {
        isSyncing = true
        let clip = scroll.contentView
        // AppKit overlays the ruler inside the clip view and reserves it using
        // contentInsets. The unscrolled x is negative, not zero. Let AppKit
        // constrain both axes so restoration cannot slide text under the ruler.
        let proposed = NSRect(origin: point, size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        scroll.reflectScrolledClipView(clip)
        isSyncing = false
    }

    func sync(to point: NSPoint) {
        isSyncing = true
        let clip = scroll.contentView
        let maxY = max(0, text.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(point.y, maxY)))
        scroll.reflectScrolledClipView(clip)
        isSyncing = false
    }

    func readingPosition() -> PaneReadingPosition {
        let source = lines.filter { $0.number != nil }.map(\.text)
        func anchor(_ index: Int) -> ReadingTextAnchor {
            let point = position(at: index) ?? (line: 0, character: 0)
            return ReadingTextAnchor(line: point.line, character: point.character, lines: source)
        }
        let origin = scroll.contentView.bounds.origin
        let character: Int
        if let layout = text.layoutManager, let container = text.textContainer {
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: max(0, origin.y - text.textContainerOrigin.y)), in: container)
            character = glyph < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyph) : 0
        } else { character = 0 }
        let row = offsets.lastIndex(where: { $0 <= character }) ?? 0
        let sourceRow = lines.indices.dropFirst(row).first { lines[$0].number != nil }
            ?? lines.indices.reversed().first { lines[$0].number != nil } ?? 0
        let line = lines.indices.contains(sourceRow) ? (lines[sourceRow].number ?? 1) - 1 : 0
        let selection = text.selectedRange()
        let topY = offsets.indices.contains(sourceRow) ? self.topY(for: offsets[sourceRow]) : 0
        return PaneReadingPosition(start: anchor(selection.location), end: anchor(NSMaxRange(selection)),
            top: ReadingTextAnchor(line: line, lines: source),
            verticalOffset: origin.y - topY,
            horizontalOffset: origin.x)
    }

    func restore(_ position: PaneReadingPosition) {
        let source = lines.filter { $0.number != nil }.map(\.text)
        func location(_ anchor: ReadingTextAnchor) -> Int {
            let line = anchor.resolvedLine(in: source)
            guard let row = lines.firstIndex(where: { $0.number == line + 1 }) else { return 0 }
            return offsets[row] + min(anchor.character, (lines[row].text as NSString).length)
        }
        let start = location(position.start), end = location(position.end)
        text.setSelectedRange(NSRange(location: min(start, end), length: abs(end - start)))
        layoutSubtreeIfNeeded()
        if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
        let topLine = position.top.resolvedLine(in: source)
        let row = lines.firstIndex { $0.number == topLine + 1 } ?? 0
        let y = (offsets.indices.contains(row) ? topY(for: offsets[row]) : 0) + position.verticalOffset
        scrollTo(NSPoint(x: position.horizontalOffset, y: y))
    }

    private func topY(for character: Int) -> Double {
        guard let layout = text.layoutManager, character < (text.string as NSString).length else { return text.textContainerOrigin.y }
        let glyph = layout.glyphIndexForCharacter(at: character)
        return text.textContainerOrigin.y + layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }

    func position(at index: Int) -> (line: Int, character: Int)? {
        guard !lines.isEmpty else { return nil }
        var low = 0
        var high = offsets.count
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] <= index { low = mid + 1 } else { high = mid }
        }
        let row = max(0, low - 1)
        guard let number = lines[row].number else { return nil }
        return (number - 1, max(0, min(index - offsets[row], (lines[row].text as NSString).length)))
    }

    func characterRange(startLine: Int, startCharacter: Int, endLine: Int, endCharacter: Int) -> NSRange? {
        guard startLine >= 0, endLine >= startLine, startCharacter >= 0, endCharacter >= 0,
              let startRow = lines.firstIndex(where: { $0.number == startLine + 1 }),
              let endRow = lines.firstIndex(where: { $0.number == endLine + 1 }),
              startCharacter <= (lines[startRow].text as NSString).length, endCharacter <= (lines[endRow].text as NSString).length else { return nil }
        let start = offsets[startRow] + startCharacter
        let end = offsets[endRow] + endCharacter
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func reveal(line: Int, character: Int = 0, highlightDestination: Bool = false) {
        guard let row = lines.firstIndex(where: { $0.number == line + 1 }) else { return }
        let location = offsets[row] + min(character, (lines[row].text as NSString).length)
        text.setSelectedRange(NSRange(location: location, length: 0))
        text.scrollRangeToVisible(NSRange(location: location, length: 0))
        window?.makeFirstResponder(text)
        if highlightDestination { text.flashNavigation(at: location) }
    }

    func reveal(row: Int) {
        guard offsets.indices.contains(row) else { return }
        text.setSelectedRange(NSRange(location: offsets[row], length: 0))
        text.scrollRangeToVisible(NSRange(location: offsets[row], length: 0))
        text.showFindIndicator(for: NSRange(location: offsets[row], length: max(1, (lines[row].text as NSString).length)))
    }
}
