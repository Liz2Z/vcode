import AppKit

final class EditorTabs: NSView, NSDraggingSource {
    var onSelect: ((ReadingDocument) -> Void)?
    var onClose: ((ReadingDocument) -> Void)?
    var onCloseGroup: ((ReadingDocument, ReadingCloseScope) -> Void)?
    var onMove: ((ReadingDocument, Int) -> Void)?
    private var documents: [ReadingDocument] = []
    private let scroll = TabScrollView()
    private let stack = NSStackView()
    private let dropIndicator = TabDropIndicator()
    private var boundsObserver: NSObjectProtocol?
    private var pendingReveal = false
    private var viewportWidth: CGFloat = 0
    private var overflowing = false
    override var intrinsicContentSize: NSSize {
        let track = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        return NSSize(width: NSView.noIntrinsicMetric, height: 40 + (overflowing ? track : 0))
    }
    private static let dragType = NSPasteboard.PasteboardType("dev.vcode.editor-tab")
    private let dragToken = UUID().uuidString
    private var draggingDocument: ReadingDocument?
    private var insertionIndex: Int?
    private var groupFocused = true
    private var activeID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .height
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 32).isActive = true
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        // Keep the native thumb available for dragging while the strip is idle.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.horizontalScrollElasticity = .none
        Theme.compactScrollers(scroll)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        scroll.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.refreshHover() }
        add(scroll)
        dropIndicator.isHidden = true
        Theme.rounded(dropIndicator, radius: 1, color: Theme.accent)
        addSubview(dropIndicator)
        registerForDraggedTypes([Self.dragType])
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Layout.controlGap), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) } }

    override func layout() {
        let overflowing = stack.fittingSize.width > max(0, bounds.width - 16) + 0.5
        if self.overflowing != overflowing {
            self.overflowing = overflowing
            invalidateIntrinsicContentSize()
        }
        super.layout()
        let width = scroll.contentSize.width
        stack.setFrameSize(NSSize(width: max(stack.fittingSize.width, width), height: 32))
        if pendingReveal || abs(width - viewportWidth) > 0.5 {
            if let active = stack.arrangedSubviews.first(where: { view in
                view.subviews.contains { $0.identifier?.rawValue == activeID }
            }) { stack.scrollToVisible(active.frame) }
        }
        pendingReveal = false
        viewportWidth = width
        scroll.scrollHorizontally(to: scroll.contentView.bounds.minX)
        refreshHover()
    }

    private func refreshHover() {
        for case let content as TabContent in stack.arrangedSubviews {
            content.refreshHover()
            for case let button as FeedbackButton in content.subviews { button.refreshHover() }
        }
    }

    func show(_ session: ReaderSession, revealActive: Bool = true) {
        let previousOffset = scroll.contentView.bounds.origin
        clearDropIndicator()
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        documents = session.documents
        activeID = session.activeDocument?.id
        for document in documents {
            let path = document.path
            let active = document == session.activeDocument
            let content = TabContent(active: active)
            content.groupFocused = groupFocused
            let title = TabTitleButton(frame: .zero)
            title.activationView = content
            content.onMouseDown = { [weak title] event in title?.mouseDown(with: event) }
            title.onPress = { [weak content] pressed in content?.setPressed(pressed) }
            title.onDrag = { [weak self, weak content] event in
                guard let self, let content else { return }
                self.beginDrag(document, content: content, event: event)
            }
            title.title = (path as NSString).lastPathComponent + (document.comparison == .staged ? " · Staged" : document.comparison == .unstaged ? " · Unstaged" : "")
            title.target = self; title.action = #selector(selectTab(_:))
            title.identifier = NSUserInterfaceItemIdentifier(document.id)
            title.bezelStyle = .smallSquare
            title.isBordered = false
            title.setButtonType(.momentaryChange)
            title.focusRingType = .none
            if let cell = title.cell as? NSButtonCell {
                cell.highlightsBy = []
                cell.showsStateBy = []
                cell.lineBreakMode = .byTruncatingMiddle
            }
            title.alignment = .left
            title.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
            title.contentTintColor = active ? (groupFocused ? Theme.accent : Theme.text) : Theme.muted
            title.setAccessibilityValue(active ? 1 : 0)
            title.imagePosition = .noImage
            title.toolTip = path + (document.comparison.map { " · " + $0.rawValue } ?? " · Source")
            let close = Theme.button("xmark", tooltip: "Close tab", target: self, action: #selector(closeTab(_:)))
            close.feedbackRadius = 4
            close.identifier = NSUserInterfaceItemIdentifier(document.id)
            let menu = contextMenu(for: document, session: session)
            content.menu = menu
            title.menu = menu
            close.menu = menu
            content.add(title, close)
            NSLayoutConstraint.activate([
                content.heightAnchor.constraint(equalToConstant: 32), content.widthAnchor.constraint(greaterThanOrEqualToConstant: 145), content.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
                title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: content.centerYAnchor), title.heightAnchor.constraint(equalToConstant: 28), title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
                close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4), close.centerYAnchor.constraint(equalTo: content.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24)
            ])
            stack.addArrangedSubview(content)
        }
        stack.layoutSubtreeIfNeeded()
        pendingReveal = revealActive
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !revealActive { scroll.scrollHorizontally(to: previousOffset.x) }
    }

    func setGroupFocused(_ focused: Bool) {
        groupFocused = focused
        for case let content as TabContent in stack.arrangedSubviews {
            content.groupFocused = focused
            for case let title as TabTitleButton in content.subviews {
                let active = title.identifier?.rawValue == activeID
                title.contentTintColor = active ? (focused ? Theme.accent : Theme.text) : Theme.muted
            }
        }
    }

    @objc private func selectTab(_ button: NSButton) { if let document = documents.first(where: { $0.id == button.identifier?.rawValue }) { onSelect?(document) } }
    @objc private func closeTab(_ button: NSButton) { if let document = documents.first(where: { $0.id == button.identifier?.rawValue }) { onClose?(document) } }

    private struct CloseRequest {
        let document: ReadingDocument
        let scope: ReadingCloseScope
    }

    private func contextMenu(for document: ReadingDocument, session: ReaderSession) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for scope in ReadingCloseScope.allCases {
            let title: String
            switch scope {
            case .all: title = "Close All"
            case .others: title = "Close Others"
            case .right: title = "Close to the Right"
            case .left: title = "Close to the Left"
            }
            let item = NSMenuItem(title: title, action: #selector(closeGroup(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = CloseRequest(document: document, scope: scope)
            item.isEnabled = !session.documentsToClose(scope, relativeTo: document).isEmpty
            menu.addItem(item)
        }
        return menu
    }

    @objc private func closeGroup(_ item: NSMenuItem) {
        guard let request = item.representedObject as? CloseRequest,
              documents.contains(request.document) else { return }
        onCloseGroup?(request.document, request.scope)
    }

    private func beginDrag(_ document: ReadingDocument, content: NSView, event: NSEvent) {
        guard documents.count > 1, documents.contains(document),
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(bitmap)
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(dragToken, forType: Self.dragType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        item.setDraggingFrame(convert(content.bounds, from: content), contents: image)
        draggingDocument = document
        beginDraggingSession(with: [item], event: event, source: self).animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggingDocument = nil
        clearDropIndicator()
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? EditorTabs) === self
            && sender.draggingPasteboard.string(forType: Self.dragType) == dragToken
            && draggingDocument.map { documents.contains($0) } == true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { clearDropIndicator(); return [] }
        // Periodic native drag updates keep scrolling while the pointer rests at an edge.
        let clip = scroll.contentView
        let point = clip.convert(sender.draggingLocation, from: nil)
        let delta: CGFloat = point.x < clip.bounds.minX + 24 ? -16 : point.x > clip.bounds.maxX - 24 ? 16 : 0
        if delta != 0 {
            scroll.scrollHorizontally(to: clip.bounds.minX + delta)
        }
        let location = stack.convert(sender.draggingLocation, from: nil)
        let index = stack.arrangedSubviews.firstIndex { location.x < $0.frame.midX } ?? documents.count
        insertionIndex = index
        let x = index < stack.arrangedSubviews.count ? stack.arrangedSubviews[index].frame.minX - 2 : (stack.arrangedSubviews.last?.frame.maxX ?? 0) + 2
        var frame = convert(NSRect(x: x, y: 4, width: 2, height: 24), from: stack)
        frame.origin.x = min(max(frame.minX, scroll.frame.minX), scroll.frame.maxX - 2)
        dropIndicator.frame = frame
        dropIndicator.isHidden = false
        return .move
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDropIndicator() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender), let document = draggingDocument, let index = insertionIndex else { return false }
        clearDropIndicator()
        onMove?(document, index)
        return true
    }

    private func clearDropIndicator() {
        insertionIndex = nil
        dropIndicator.isHidden = true
    }
}

private final class TabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // AppKit already applies natural-scroll direction and momentum to these
        // deltas. Use the dominant axis so diagonal gestures aren't counted twice.
        let x = event.scrollingDeltaX, y = event.scrollingDeltaY
        let delta = abs(x) >= abs(y) ? x : y
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : horizontalLineScroll
        scrollHorizontally(to: contentView.bounds.minX - delta * scale)
    }

    func scrollHorizontally(to x: CGFloat) {
        let clip = contentView
        let proposed = NSRect(x: x, y: 0, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(clip)
    }
}

private final class TabDropIndicator: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TabContent: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    var groupFocused = true { didSet { updateFeedback() } }
    private var tracking: NSTrackingArea?
    private let active: Bool
    private var hovered = false
    private var pressed = false

    init(active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.controlRadius
        updateFeedback()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }

    override func resetCursorRects() {
        super.resetCursorRects()
        if onMouseDown != nil, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty {
            addCursorRect(visibleRect, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        refreshHover()
    }

    func refreshHover() {
        hovered = containsVisibleWindowMouse
        window?.invalidateCursorRects(for: self)
        updateFeedback()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    func setPressed(_ value: Bool) { pressed = value; updateFeedback() }
    private func updateFeedback() {
        let selected = groupFocused ? Theme.surface : Theme.surface.withAlphaComponent(0.5)
        let color: NSColor = pressed ? Theme.accent.withAlphaComponent(0.24) : active ? (hovered ? selected.blended(withFraction: 0.12, of: .white)! : selected) : hovered ? NSColor.white.withAlphaComponent(0.08) : .clear
        layer?.backgroundColor = color.cgColor
    }
}

private final class TabTitleButton: PointingHandButton {
    weak var activationView: NSView?
    var onPress: ((Bool) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        if event.modifierFlags.contains(.control), let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        onPress?(true)
        defer { onPress?(false) }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .leftMouseUp {
                let region = activationView ?? self
                if region.bounds.contains(region.convert(next.locationInWindow, from: nil)) { _ = sendAction(action, to: target) }
                return
            }
            if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) >= 4 {
                onPress?(false)
                onDrag?(next)
                return
            }
        }
    }
}
