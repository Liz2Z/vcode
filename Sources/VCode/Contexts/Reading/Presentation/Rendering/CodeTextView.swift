import AppKit

final class CodeTextView: NSTextView {
    var onTextChange: (() -> Void)?
    var onWillChangeText: (() -> Void)?
    var onFindAction: ((NSTextFinder.Action) -> Void)?
    var isPointerObscured: ((NSPoint) -> Bool)?
    private(set) var searchRanges: [NSRange] = []
    private(set) var currentSearchRange: NSRange?
    private(set) var isFindSelection = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        isFindSelection = false
        selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsDisplay(visibleRect)
    }

    func selectSearchMatch(_ range: NSRange) {
        setSelectedRange(range)
        // Navigation keeps a real selection for copy and subsequent Find actions,
        // but its appearance comes from the dedicated current-match renderer.
        isFindSelection = true
        selectedTextAttributes = [.backgroundColor: NSColor.clear]
        setNeedsDisplay(visibleRect)
    }

    func setCurrentSearchMatch(_ range: NSRange?) {
        currentSearchRange = range.flatMap { searchRanges.contains($0) ? $0 : nil }
        (layoutManager as? CodeLayoutManager)?.currentSearchRange = currentSearchRange
        setNeedsDisplay(visibleRect)
    }

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        onWillChangeText?()
        return true
    }

    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSValidatedUserInterfaceItem,
              let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        onFindAction?(action)
    }

    func setSearchMatches(_ ranges: [NSRange]) {
        let length = (string as NSString).length
        searchRanges = ranges.filter { $0.location >= 0 && $0.length > 0 && $0.location <= length && $0.length <= length - $0.location }
        (layoutManager as? CodeLayoutManager)?.searchRanges = searchRanges
        setCurrentSearchMatch(nil)
        if isFindSelection {
            isFindSelection = false
            selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor, .foregroundColor: NSColor.selectedTextColor]
        }
        setNeedsDisplay(visibleRect)
    }

    override func didChangeText() {
        super.didChangeText()
        resetSymbolFeedback()
        onTextChange?()
    }

    var onInspect: ((Int, String) -> Void)?
    var onCursor: ((Int) -> Void)?
    var onHoverInvalidated: (() -> Void)?
    var onHoverExited: (() -> Void)?
    var onHoverMoved: ((NSPoint) -> Void)?
    var onDefinitionProbe: ((Int, @escaping (Bool) -> Void) -> Void)?
    var onSymbolClick: ((Int, @escaping ([NSRange]) -> Void) -> Void)?
    var onOccurrencesChanged: (([NSRange]) -> Void)?
    private var hoverWork: DispatchWorkItem?
    private var tracking: NSTrackingArea?
    private(set) var hoveredIdentifier: NSRange?
    private var contextIdentifier: NSRange?
    private var navigationTimer: Timer?
    private(set) var navigationFlashRange: NSRange?
    static let navigationFlashDuration: TimeInterval = 2
    private var commandWork: DispatchWorkItem?
    private var commandToken = UUID()
    private var symbolToken = UUID()
    private var commandHeld = false
    private var modifierMonitor: Any?
    private var commandCandidate: NSRange?
    private(set) var underlinedIdentifier: NSRange?
    private(set) var occurrenceRanges: [NSRange] = []

    func flashNavigation(at index: Int) {
        cancelNavigationFlash()
        let source = string as NSString
        guard index >= 0, index < source.length, let layout = layoutManager as? CodeLayoutManager else { return }
        let range = Self.identifier(in: source, at: index) ?? source.rangeOfComposedCharacterSequence(at: index)
        guard source.substring(with: range).rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil else { return }
        navigationFlashRange = range
        layout.navigationRange = range
        layout.navigationAlpha = 0.48
        invalidateNavigationDisplay(range)
        let start = ProcessInfo.processInfo.systemUptime
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] timer in
            guard let self, self.navigationTimer === timer else { timer.invalidate(); return }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            guard elapsed < Self.navigationFlashDuration else { self.cancelNavigationFlash(); return }
            layout.navigationAlpha = reduceMotion ? 0.3 : (Int(elapsed * 3).isMultiple(of: 2) ? 0.48 : 0)
            self.invalidateNavigationDisplay(range)
        }
        navigationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelNavigationFlash() {
        navigationTimer?.invalidate()
        navigationTimer = nil
        if let layout = layoutManager as? CodeLayoutManager {
            layout.navigationRange = nil
            if let range = navigationFlashRange, NSMaxRange(range) <= (textStorage?.length ?? 0) { invalidateNavigationDisplay(range) }
        }
        navigationFlashRange = nil
    }

    private func invalidateNavigationDisplay(_ range: NSRange) {
        guard let layout = layoutManager, let container = textContainer else { return }
        layout.invalidateDisplay(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: -4, dy: -2).integral
        // The rounded highlight extends beyond the glyphs. Invalidate its full
        // bounds as well so the padding cannot leave a stale edge behind.
        setNeedsDisplay(rect)
    }

    deinit { navigationTimer?.invalidate(); commandWork?.cancel(); if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor) }
        modifierMonitor = nil
        clearCommandFeedback()
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self, weak window] event in
            guard let self, let window, window.isKeyWindow, !self.isHiddenOrHasHiddenAncestor else { return event }
            self.updatePointer(at: self.convert(window.mouseLocationOutsideOfEventStream, from: nil), modifiers: event.modifierFlags)
            return event
        }
    }

    func resetSymbolFeedback() {
        clearCommandFeedback()
        symbolToken = UUID()
        setOccurrences([])
    }

    func highlightSymbol(at index: Int?) {
        symbolToken = UUID()
        guard let index, Self.identifier(in: string as NSString, at: index) != nil else { setOccurrences([]); return }
        let token = symbolToken
        let source = string
        setOccurrences([])
        onSymbolClick?(index) { [weak self] ranges in
            guard let self, self.symbolToken == token, self.string == source else { return }
            self.setOccurrences(Array(Set(ranges)).sorted { $0.location < $1.location })
        }
    }

    private func setOccurrences(_ ranges: [NSRange]) {
        occurrenceRanges = ranges.filter { $0.location >= 0 && $0.length > 0 && $0.location <= (string as NSString).length && $0.length <= (string as NSString).length - $0.location }
        (layoutManager as? CodeLayoutManager)?.symbolRanges = occurrenceRanges
        onOccurrencesChanged?(occurrenceRanges)
        // Only redraw the visible viewport; thousands of occurrences must not
        // force text layout for the whole document on every selection.
        setNeedsDisplay(visibleRect)
    }

    private func clearCommandFeedback(restoreCursor: Bool = true) {
        commandToken = UUID()
        commandWork?.cancel()
        commandWork = nil
        if let range = underlinedIdentifier {
            layoutManager?.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager?.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
            if restoreCursor { NSCursor.iBeam.set() }
        }
        underlinedIdentifier = nil
        commandCandidate = nil
    }

    private func updateCommandHover(at point: NSPoint) {
        guard !isEditable else { return }
        let range = visibleRect.contains(point) ? identifier(at: point) : nil
        if range == commandCandidate {
            if underlinedIdentifier != nil { NSCursor.pointingHand.set() }
            return
        }
        clearCommandFeedback()
        guard let range else { return }
        commandCandidate = range
        let token = commandToken
        let source = string
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.commandHeld, self.commandToken == token else { return }
            self.onDefinitionProbe?(range.location + range.length / 2) { [weak self] available in
                guard let self, self.commandHeld, self.commandToken == token, self.string == source else { return }
                guard available else { return }
                self.underlinedIdentifier = range
                self.layoutManager?.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
                self.layoutManager?.addTemporaryAttribute(.underlineColor, value: Theme.accent, forCharacterRange: range)
                NSCursor.pointingHand.set()
            }
        }
        commandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if isEditable { return super.menu(for: event) }
        cancelInspection()
        contextIdentifier = identifier(at: convert(event.locationInWindow, from: nil))
        let menu = NSMenu()
        if contextIdentifier != nil {
            let references = NSMenuItem(title: "Find References", action: #selector(findReferences), keyEquivalent: "")
            references.target = self
            menu.addItem(references)
        }
        if selectedRange().length > 0 {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
        }
        return menu.items.isEmpty ? nil : menu
    }

    @objc private func findReferences() {
        guard let range = contextIdentifier else { return }
        onInspect?(range.location + range.length / 2, "references")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    // Hit the actual glyph, rather than the nearest insertion point (which may
    // fall on the next dot/member when clicking the right half of a character).
    func identifier(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager, let container = textContainer, !string.isEmpty else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs,
              layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return Self.identifier(in: string as NSString, at: layout.characterIndexForGlyph(at: glyph))
    }

    static func identifier(in source: NSString, at index: Int) -> NSRange? {
        guard index >= 0, index < source.length else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).union(.nonBaseCharacters)
        let unit = source.rangeOfComposedCharacterSequence(at: index)
        guard source.substring(with: unit).rangeOfCharacter(from: allowed) != nil else { return nil }
        let before = source.rangeOfCharacter(from: allowed.inverted, options: .backwards, range: NSRange(location: 0, length: unit.location))
        let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
        let after = source.rangeOfCharacter(from: allowed.inverted, range: NSRange(location: NSMaxRange(unit), length: source.length - NSMaxRange(unit)))
        let end = after.location == NSNotFound ? source.length : after.location
        let range = NSRange(location: start, length: end - start)
        guard source.substring(with: range).rangeOfCharacter(from: .letters.union(CharacterSet(charactersIn: "_$"))) != nil else { return nil }
        return range
    }

    override func mouseEntered(with event: NSEvent) {
        guard !skipObscuredPointer(at: event.locationInWindow) else { return }
        super.mouseEntered(with: event); updateHover(event)
    }
    override func mouseMoved(with event: NSEvent) {
        guard !skipObscuredPointer(at: event.locationInWindow) else { return }
        super.mouseMoved(with: event); updateHover(event)
    }

    private func skipObscuredPointer(at windowPoint: NSPoint) -> Bool {
        guard isPointerObscured?(windowPoint) == true else { return false }
        clearCommandFeedback(restoreCursor: false)
        clearInspectionFeedback()
        onHoverInvalidated?()
        return true
    }

    private func updateHover(_ event: NSEvent) {
        guard !isEditable else { return }
        let point = convert(event.locationInWindow, from: nil)
        updatePointer(at: point, modifiers: event.modifierFlags)
    }

    private func updatePointer(at point: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard !isEditable, !skipObscuredPointer(at: convert(point, to: nil)) else { return }
        let wasCommandHeld = commandHeld
        commandHeld = modifiers.contains(.command)
        if commandHeld {
            if !wasCommandHeld || hoveredIdentifier != nil { clearInspectionFeedback(); onHoverInvalidated?() }
            updateCommandHover(at: point)
        } else {
            clearCommandFeedback()
            updateHover(at: point)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard let window else { clearCommandFeedback(); return }
        guard !skipObscuredPointer(at: window.mouseLocationOutsideOfEventStream) else { return }
        super.flagsChanged(with: event)
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updatePointer(at: point, modifiers: event.modifierFlags)
    }

    private func updateHover(at point: NSPoint) {
        let screenPoint = window?.convertPoint(toScreen: convert(point, to: nil))
        defer { if let screenPoint { onHoverMoved?(screenPoint) } }
        let range = visibleRect.contains(point) ? identifier(at: point) : nil
        guard range != hoveredIdentifier else { return }
        clearInspectionFeedback()
        onHoverExited?()
        guard let range else { return }
        hoveredIdentifier = range
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredIdentifier == range else { return }
            self.onInspect?(range.location + range.length / 2, "hover")
        }
        hoverWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    func clearInspectionFeedback() {
        hoverWork?.cancel()
        hoverWork = nil
        hoveredIdentifier = nil
    }

    func cancelInspection() {
        clearCommandFeedback()
        clearInspectionFeedback()
        onHoverInvalidated?()
    }

    override func mouseExited(with event: NSEvent) {
        guard !skipObscuredPointer(at: event.locationInWindow) else { return }
        clearCommandFeedback()
        clearInspectionFeedback()
        onHoverExited?()
        super.mouseExited(with: event)
    }

    override func scrollWheel(with event: NSEvent) { cancelInspection(); super.scrollWheel(with: event) }

    override func keyDown(with event: NSEvent) {
        clearInspectionFeedback()
        onHoverInvalidated?()
        if !event.modifierFlags.contains(.command) { clearCommandFeedback() }
        if event.keyCode == 53 { onFindAction?(.hideFindInterface) }
        if event.keyCode != 53 { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if isEditable { super.mouseDown(with: event); onCursor?(selectedRange().location); return }
        cancelInspection()
        if event.modifierFlags.contains(.command) {
            if let range = identifier(at: convert(event.locationInWindow, from: nil)) {
                onInspect?(range.location + range.length / 2, "definition")
            }
        } else {
            let clicked = identifier(at: convert(event.locationInWindow, from: nil))
            super.mouseDown(with: event)
            onCursor?(selectedRange().location)
            let singleClick = selectedRange().length == 0 || (event.clickCount == 2 && selectedRange() == clicked)
            highlightSymbol(at: singleClick ? clicked.map { $0.location + $0.length / 2 } : nil)
            // A released click leaves the pointer hovering too. Keep selection
            // gestures quiet, but allow a stationary identifier to show its type.
            if selectedRange().length == 0 {
                updateHover(event)
            }
        }
    }
}
