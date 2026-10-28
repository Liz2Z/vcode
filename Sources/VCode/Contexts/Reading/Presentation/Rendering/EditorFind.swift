import AppKit

/// Literal matching uses Foundation's Unicode-aware regular expression engine.
/// Work stays off the main thread and belongs to one editor group and version.
final class EditorFind {
    private let bar: EditorFindBar
    private(set) weak var currentPane: CodePane?
    private let queue = DispatchQueue(label: "dev.vcode.editor-find", qos: .userInitiated)
    private var request: SearchRequest?
    private(set) var matches: [NSRange] = []
    private(set) var currentIndex: Int?

    init(bar: EditorFindBar) {
        self.bar = bar
        bar.onQuery = { [weak self] in self?.search() }
        bar.onNavigate = { [weak self] forward in self?.navigate(forward: forward) }
        bar.onClose = { [weak self] in self?.close() }
    }
    deinit { request?.cancel() }

    func perform(_ action: NSTextFinder.Action, in pane: CodePane) {
        if currentPane !== pane {
            close(restoreFocus: false)
            currentPane = pane
        }
        switch action {
        case .showFindInterface:
            let selection = pane.text.selectedRange()
            let source = pane.text.string as NSString
            if selection.length > 0, selection.length < 1024, NSMaxRange(selection) <= source.length {
                let selected = source.substring(with: selection)
                if !selected.contains("\n") { bar.query.stringValue = selected }
            }
            bar.isFindBarVisible = true
            search()
            pane.window?.makeFirstResponder(bar.query)
            bar.query.selectText(nil)
        case .nextMatch, .previousMatch:
            if !bar.isFindBarVisible {
                bar.isFindBarVisible = true
                search(arrival: action == .nextMatch)
            } else { navigate(forward: action == .nextMatch) }
        case .hideFindInterface: close()
        default: break
        }
    }

    func close(restoreFocus: Bool = true) {
        request?.cancel(); request = nil
        matches = []; currentIndex = nil
        bar.isFindBarVisible = false
        currentPane?.setSearchMatches([])
        bar.showResult(index: nil, count: 0)
        if restoreFocus, let pane = currentPane { pane.window?.makeFirstResponder(pane.text) }
    }

    func willChangeText(in pane: CodePane, replacing: Bool = false) {
        guard currentPane === pane else { return }
        if replacing { close(restoreFocus: false) }
        request?.cancel(); request = nil
        matches = []; currentIndex = nil
        pane.setSearchMatches([])
    }

    func didChangeText(in pane: CodePane) {
        if currentPane === pane, bar.isFindBarVisible { search(reveal: false) }
    }

    func search(arrival: Bool? = nil, reveal: Bool = true) {
        request?.cancel()
        matches = []; currentIndex = nil
        guard let pane = currentPane, bar.isFindBarVisible else { return }
        pane.setSearchMatches([])
        let query = bar.query.stringValue
        guard !query.isEmpty else { bar.showResult(index: nil, count: 0); return }
        let source = pane.text.string
        let request = SearchRequest()
        self.request = request
        let sensitive = bar.matchCase.state == .on
        let wholeWord = bar.wholeWord.state == .on
        bar.count.stringValue = "…"
        queue.async { [weak self, weak pane] in
            let matches = Self.find(query, in: source, matchCase: sensitive, wholeWord: wholeWord, cancelled: { request.isCancelled })
            DispatchQueue.main.async { [weak self, weak pane] in
                guard let self, let pane, self.request === request, !request.isCancelled,
                      self.bar.isFindBarVisible, self.currentPane === pane, pane.text.string == source else { return }
                self.matches = matches
                pane.setSearchMatches(matches)
                let location = pane.text.selectedRange().location
                if arrival == false { self.currentIndex = matches.lastIndex { $0.location < location } ?? matches.indices.last }
                else { self.currentIndex = matches.firstIndex { $0.location >= location } ?? matches.indices.first }
                if reveal { self.revealCurrent() }
                else {
                    pane.setCurrentSearchMatch(self.currentIndex.map { matches[$0] })
                    self.bar.showResult(index: self.currentIndex, count: matches.count)
                }
            }
        }
    }

    static func find(_ query: String, in source: String, matchCase: Bool, wholeWord: Bool, cancelled: () -> Bool = { false }) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let literal = NSRegularExpression.escapedPattern(for: query)
        let pattern = wholeWord ? "(?<![\\p{L}\\p{N}_$])" + literal + "(?![\\p{L}\\p{N}_$])" : literal
        guard let regex = try? NSRegularExpression(pattern: pattern, options: matchCase ? [] : [.caseInsensitive]) else { return [] }
        var result: [NSRange] = []
        regex.enumerateMatches(in: source, options: [.reportProgress], range: NSRange(location: 0, length: (source as NSString).length)) { match, _, stop in
            if cancelled() { stop.pointee = true; return }
            if let match { result.append(match.range) }
        }
        return result
    }

    private func navigate(forward: Bool) {
        guard let pane = currentPane, !matches.isEmpty else { return }
        let selection = pane.text.selectedRange()
        if let index = currentIndex, matches[index] == selection {
            currentIndex = (index + (forward ? 1 : matches.count - 1)) % matches.count
        } else if forward {
            currentIndex = matches.firstIndex { $0.location >= NSMaxRange(selection) } ?? matches.indices.first
        } else {
            currentIndex = matches.lastIndex { $0.location < selection.location } ?? matches.indices.last
        }
        revealCurrent()
    }

    private func revealCurrent() {
        bar.showResult(index: currentIndex, count: matches.count)
        guard let pane = currentPane, let currentIndex, matches.indices.contains(currentIndex) else { return }
        let range = matches[currentIndex]
        pane.setCurrentSearchMatch(range)
        pane.text.selectSearchMatch(range)
        pane.text.scrollRangeToVisible(range)
        pane.text.onCursor?(range.location)
    }
}

private final class SearchRequest {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Floating, compact controls; the native input and buttons keep normal macOS
/// editing and accessibility behavior without allocating a row above the code.
final class EditorFindBar: NSView, NSSearchFieldDelegate {
    let query = Theme.searchField()
    let count = Theme.label("", size: 11, color: Theme.muted)
    let matchCase = Theme.button("", tooltip: "Match Case", target: nil, action: nil)
    let wholeWord = Theme.button("", tooltip: "Match Whole Word", target: nil, action: nil)
    let previous = Theme.button("chevron.up", tooltip: "Previous Match (⇧Return / ⌘⇧G)", target: nil, action: nil)
    let next = Theme.button("chevron.down", tooltip: "Next Match (Return / ⌘G)", target: nil, action: nil)
    let closeButton = Theme.button("xmark", tooltip: "Close Find (Escape)", target: nil, action: nil)
    var onQuery: (() -> Void)?
    var onNavigate: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private var pointerAreas: [NSTrackingArea] = []
    var isFindBarVisible: Bool {
        get { !isHidden }
        set { isHidden = !newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let content = NSView()
        let surface = GlassSurface(content: content, radius: 10, tintColor: nil, fallbackMaterial: .popover)
        surface.layer?.masksToBounds = false
        add(surface)
        Theme.pin(surface, to: self)
        // Keep the floating control distinct over a nearly uniform code surface.
        // The background itself remains the system's native glass material.
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        Theme.setLayerColor(Theme.muted.withAlphaComponent(0.32), on: layer, property: .border)
        Theme.setLayerColor(Theme.shadow, on: layer, property: .shadow)
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 8
        layer?.shadowOffset = NSSize(width: 0, height: -3)
        query.placeholderString = "Find in editor"
        query.setAccessibilityLabel("Find in editor")
        query.sendsSearchStringImmediately = true
        query.sendsWholeSearchString = false
        query.delegate = self
        count.setAccessibilityLabel("Find results")
        count.alignment = .right
        count.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, title) in [(matchCase, "Aa"), (wholeWord, "ab")] {
            button.title = title
            button.imagePosition = .noImage
            button.horizontalPadding = 4
            button.setButtonType(.toggle)
            button.target = self; button.action = #selector(optionsChanged)
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        }
        previous.target = self; previous.action = #selector(previousMatch)
        next.target = self; next.action = #selector(nextMatch)
        closeButton.target = self; closeButton.action = #selector(closeFind)
        for button in [previous, next, closeButton] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        let top = NSStackView(views: [query, count, closeButton])
        top.orientation = .horizontal; top.spacing = 6; top.alignment = .centerY
        let spacer = NSView()
        let bottom = NSStackView(views: [matchCase, wholeWord, spacer, previous, next])
        bottom.orientation = .horizontal; bottom.spacing = 4; bottom.alignment = .centerY
        content.add(top, bottom)
        let countWidth = count.widthAnchor.constraint(equalToConstant: 66)
        countWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 8), top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            query.heightAnchor.constraint(equalToConstant: 28), query.widthAnchor.constraint(greaterThanOrEqualToConstant: 30), countWidth, count.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 4), bottom.leadingAnchor.constraint(equalTo: top.leadingAnchor), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6), bottom.heightAnchor.constraint(equalToConstant: 24)
        ])
        isHidden = true
        showResult(index: nil, count: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 10, cornerHeight: 10, transform: nil)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in pointerAreas { removeTrackingArea(area) }
        // AppKit does not permit cursorUpdate together with activeAlways.
        pointerAreas = [
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self),
            NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        ]
        for area in pointerAreas { addTrackingArea(area) }
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isHiddenOrHasHiddenAncestor else { return }
        for button in [matchCase, wholeWord, previous, next, closeButton] where button.isEnabled {
            let rect = convert(button.bounds.intersection(button.visibleRect), from: button).intersection(bounds.intersection(visibleRect))
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }
    override func mouseEntered(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    private func updateCursor(at windowPoint: NSPoint) {
        guard !isHiddenOrHasHiddenAncestor, bounds.intersection(visibleRect).contains(convert(windowPoint, from: nil)) else { return }
        for button in [matchCase, wholeWord, previous, next, closeButton] {
            if button.bounds.intersection(button.visibleRect).contains(button.convert(windowPoint, from: nil)) {
                (button.isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
                return
            }
        }
        let inputPoint = query.convert(windowPoint, from: nil)
        if query.bounds.intersection(query.visibleRect).contains(inputPoint) {
            let cancel = query.cancelButtonBounds
            (!query.stringValue.isEmpty && cancel.contains(inputPoint) ? NSCursor.pointingHand : NSCursor.iBeam).set()
        } else { NSCursor.arrow.set() }
    }
    func showResult(index: Int?, count: Int) {
        self.count.stringValue = query.stringValue.isEmpty ? "" : count == 0 ? "No results" : "\((index ?? 0) + 1) / \(count)"
        self.count.textColor = count == 0 && !query.stringValue.isEmpty ? Theme.red : Theme.muted
        next.isEnabled = count > 0; previous.isEnabled = count > 0
        window?.invalidateCursorRects(for: self)
    }
    func controlTextDidChange(_ obj: Notification) { onQuery?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onClose?(); return true }
        if [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:))].contains(commandSelector) {
            onNavigate?(!(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)); return true
        }
        return false
    }
    @objc private func optionsChanged() {
        matchCase.isSelected = matchCase.state == .on
        wholeWord.isSelected = wholeWord.state == .on
        onQuery?()
    }
    @objc private func previousMatch() { onNavigate?(false) }
    @objc private func nextMatch() { onNavigate?(true) }
    @objc private func closeFind() { onClose?() }
}
