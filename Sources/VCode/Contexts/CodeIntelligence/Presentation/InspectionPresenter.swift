import AppKit

final class InspectionPresenter: NSObject, NSWindowDelegate {
    var onNavigate: ((CodeLocation) -> Void)?
    var onStatus: ((String) -> Void)?
    var onHoverDismiss: (() -> Void)?
    var onFindReferences: ((Int) -> Void)?
    private(set) var hoverPanel: NSPanel?
    private var hoverAnchor = NSRect.zero
    private var hoverCloseWork: DispatchWorkItem?
    private var hoverCloseToken = UUID()
    static let hoverDismissDelay: TimeInterval = 2
    private var hoverObservers: [NSObjectProtocol] = []
    private var eventMonitor: Any?
    private(set) var locationsWindow: NSWindow?
    private var locationsController: LocationsController?
    private var referenceIndex: Int?

    func show(_ value: LanguageInspection, kind: InspectionKind, index: Int, textView: NSTextView, root: URL, currentDocument: (url: URL, lines: [String])? = nil) {
        switch value {
        case .highlights: break
        case .hover(let text): showHover(text, index: index, in: textView)
        case .locations(let locations):
            let symbolRange = CodeTextView.identifier(in: textView.string as NSString, at: index)
            let symbol = symbolRange.map { (textView.string as NSString).substring(with: $0) }
            showLocations(locations, kind: kind, root: root, symbol: symbol, parent: textView.window, currentDocument: currentDocument)
        }
    }

    func dismiss() {
        dismissHover()
        locationsWindow?.close()
        locationsWindow = nil
        locationsController = nil
    }

    func dismissHover() {
        cancelHoverDismissal()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        hoverObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hoverObservers.removeAll()
        let panel = hoverPanel
        hoverPanel = nil
        referenceIndex = nil
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        onHoverDismiss?()
    }

    func dismissHoverWhenPointerLeaves() {
        guard let panel = hoverPanel, hoverCloseWork == nil else { return }
        let token = UUID()
        hoverCloseToken = token
        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, let panel, self.hoverCloseToken == token, self.hoverPanel === panel else { return }
            self.dismissHover()
        }
        hoverCloseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDismissDelay, execute: work)
    }

    func hoverPointerMoved(to point: NSPoint) {
        guard let panel = hoverPanel else { return }
        if panel.frame.contains(point) || hoverAnchor.contains(point) { cancelHoverDismissal() }
        else { dismissHoverWhenPointerLeaves() }
    }

    private func cancelHoverDismissal() {
        hoverCloseToken = UUID()
        hoverCloseWork?.cancel()
        hoverCloseWork = nil
    }

    private func showHover(_ string: String, index: Int, in textView: NSTextView) {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Replacing a hover must not clear the identifier feedback for the new one.
        let dismissCallback = onHoverDismiss
        onHoverDismiss = nil
        dismissHover()
        onHoverDismiss = dismissCallback
        guard let window = textView.window, index >= 0, index < textView.string.utf16.count else { onHoverDismiss?(); return }
        var range = CodeTextView.identifier(in: textView.string as NSString, at: index) ?? NSRange(location: index, length: 1)
        let anchor = textView.firstRect(forCharacterRange: range, actualRange: &range)
        let visible = window.convertToScreen(textView.convert(textView.visibleRect, to: nil))
        guard anchor.intersects(visible) else { onHoverDismiss?(); return }
        hoverAnchor = anchor
        let allowed = window.convertToScreen(window.contentLayoutRect).intersection(window.screen?.visibleFrame ?? window.frame).insetBy(dx: 10, dy: 10)
        guard allowed.width > 80, allowed.height > 80 else { return }
        let content = HoverTextRenderer.render(string)
        let width = min(620, allowed.width, max(260, ceil(content.size().width) + 36))
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textColor = Theme.text
        text.isAutomaticLinkDetectionEnabled = false
        text.layoutManager?.usesFontLeading = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: width - 24, height: .greatestFiniteMagnitude)
        text.textStorage?.setAttributedString(content)
        guard let container = text.textContainer, let layout = text.layoutManager else { return }
        layout.ensureLayout(for: container)
        let contentHeight = ceil(layout.usedRect(for: container).height) + 24
        let footerHeight: CGFloat = onFindReferences == nil ? 0 : 36
        let frame = HoverGeometry.frame(anchor: anchor, contentSize: NSSize(width: width, height: contentHeight + footerHeight), bounds: allowed)
        guard frame.height > 20 else { return }
        let surface = HoverSurface(frame: NSRect(origin: .zero, size: frame.size))
        surface.onEnter = { [weak self] in self?.cancelHoverDismissal() }
        surface.onExit = { [weak self] point in self?.hoverPointerMoved(to: point) }
        Theme.rounded(surface, radius: 8, color: Theme.background)
        surface.layer?.borderWidth = 1
        surface.layer?.borderColor = Theme.muted.withAlphaComponent(0.24).cgColor
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        surface.add(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 1), scroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 1), scroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -1), scroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -1 - footerHeight)
        ])
        if onFindReferences != nil {
            referenceIndex = index
            let references = Theme.actionButton("Find References", symbol: "text.magnifyingglass", target: self, action: #selector(findReferences))
            references.horizontalPadding = 8
            references.feedbackRadius = 4
            surface.add(references)
            NSLayoutConstraint.activate([
                references.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8), references.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6), references.heightAnchor.constraint(equalToConstant: 24), references.trailingAnchor.constraint(lessThanOrEqualTo: surface.trailingAnchor, constant: -8)
            ])
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = surface
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Type information")
        window.addChildWindow(panel, ordered: .above)
        hoverPanel = panel
        panel.orderFront(nil)
        surface.layoutSubtreeIfNeeded()
        text.frame.size = NSSize(width: scroll.contentSize.width, height: max(contentHeight, scroll.contentSize.height))
        layout.ensureLayout(for: container)
        text.frame.size.height = max(ceil(layout.usedRect(for: container).height) + 24, scroll.contentSize.height)
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            hoverObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.dismissHover() })
        }
        hoverObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.dismissHover() })
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown, let parent = self.hoverPanel?.parent, event.window === parent,
               event.locationInWindow.y > parent.contentLayoutRect.maxY { return event }
            if event.type == .keyDown, event.keyCode == 53 { self.dismissHover(); return nil }
            if event.window !== self.hoverPanel { self.dismissHover() }
            return event
        }
    }

    @objc private func findReferences() {
        guard let index = referenceIndex else { return }
        dismissHover()
        onFindReferences?(index)
    }

    private func showLocations(_ locations: [CodeLocation], kind: InspectionKind, root: URL?, symbol: String?, parent: NSWindow?, currentDocument: (url: URL, lines: [String])?) {
        dismissHover()
        if kind != .references, locations.isEmpty { onStatus?("No definition found"); return }
        if kind == .definition, locations.count == 1 { onNavigate?(locations[0]); return }
        locationsWindow?.close()
        let controller = LocationsController(locations: locations, root: root, references: kind == .references, currentDocument: currentDocument) { [weak self, weak parent] location in
            parent?.makeKeyAndOrderFront(nil)
            self?.onNavigate?(location)
        }
        let window = NSWindow(contentViewController: controller)
        window.title = (kind == .references ? "References" : "Definitions") + (symbol.map { " · " + $0 } ?? "")
        window.setContentSize(NSSize(width: min(760, (parent?.frame.width ?? 800) - 40), height: min(460, (parent?.frame.height ?? 520) - 60)))
        if let parent { window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2, y: parent.frame.midY - window.frame.height / 2)) }
        else { window.center() }
        window.isReleasedWhenClosed = false
        window.delegate = self
        locationsController = controller
        locationsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === locationsWindow {
            locationsController = nil
            locationsWindow = nil
        }
    }

    deinit { dismissHover() }
}

private final class HoverSurface: NSView {
    var onEnter: (() -> Void)?
    var onExit: ((NSPoint) -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if let window { onExit?(window.convertPoint(toScreen: event.locationInWindow)) }
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onEnter?() }
}
