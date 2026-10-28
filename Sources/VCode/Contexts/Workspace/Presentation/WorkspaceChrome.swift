import AppKit

final class WorkspaceHeader: NSView {
    let branchButton = Theme.actionButton("—", symbol: "arrow.triangle.branch")
    let worktreeButton = Theme.actionButton("—", symbol: "folder")
    let openButton = Theme.actionButton("Open Folder", symbol: "folder.badge.plus")
    private var isGit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        openButton.toolTip = "Open Folder (⌘O)"
        branchButton.setAccessibilityLabel("Branch")
        worktreeButton.setAccessibilityLabel("Worktree")
        worktreeButton.title = "VCode"
        worktreeButton.font = .systemFont(ofSize: 14, weight: .semibold)
        worktreeButton.disabledTint = Theme.text
        worktreeButton.toolTip = "Open a folder to begin"
        for button in [branchButton, worktreeButton] {
            button.horizontalPadding = Theme.Layout.moduleGap
            button.isEnabled = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        worktreeButton.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(252), for: .horizontal)
        add(worktreeButton, branchButton, openButton)
        NSLayoutConstraint.activate([
            worktreeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 96), worktreeButton.centerYAnchor.constraint(equalTo: centerYAnchor), worktreeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 320), worktreeButton.heightAnchor.constraint(equalToConstant: 32),
            branchButton.leadingAnchor.constraint(equalTo: worktreeButton.trailingAnchor, constant: 8), branchButton.centerYAnchor.constraint(equalTo: centerYAnchor), branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200), branchButton.heightAnchor.constraint(equalToConstant: 32), branchButton.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -16),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), openButton.centerYAnchor.constraint(equalTo: centerYAnchor), openButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: WorkspaceState) {
        isGit = state.isGit
        branchButton.title = state.isGit ? state.branch : "—"
        worktreeButton.title = state.root.lastPathComponent
        branchButton.toolTip = state.isGit ? "Switch local branch · " + state.branch : "Open a Git repository to switch branches"
        worktreeButton.toolTip = (state.isGit ? "Switch worktree · " : "Current folder · ") + state.root.path
        worktreeButton.setAccessibilityLabel(state.isGit ? "Worktree" : "Current folder")
        setBusy(false)
    }
    func setBusy(_ busy: Bool) {
        branchButton.isEnabled = isGit && !busy
        worktreeButton.isEnabled = isGit && !busy
        openButton.isEnabled = !busy
    }
}

final class WorkspaceNavigation: NSView {
    let files = Theme.actionButton("Files")
    let changes = Theme.actionButton("Changes")
    let search = Theme.actionButton("Search")
    let changesIndicator = NSView()
    private var changeCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        files.toolTip = "All files (⌘1)"
        changes.toolTip = "Changes (⌘2)"
        search.toolTip = "Search in project (⌘⇧F)"
        search.isEnabled = false
        // Keep full titles at 220 points; equal widths yield to title minima.
        for button in [files, changes, search] { button.horizontalPadding = 8 }
        add(files, changes, search)
        changesIndicator.setAccessibilityElement(false)
        changesIndicator.wantsLayer = true
        if let layer = changesIndicator.layer {
            Theme.setLayerColor(Theme.accent, on: layer)
            layer.cornerRadius = 2.5
            Theme.setLayerColor(Theme.accent, on: layer, property: .shadow)
            layer.shadowOpacity = 0.9
            layer.shadowRadius = 3.5
            layer.shadowOffset = .zero
        }
        changes.add(changesIndicator)
        let equalWidths = [files.widthAnchor.constraint(equalTo: changes.widthAnchor), files.widthAnchor.constraint(equalTo: search.widthAnchor)]
        equalWidths.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            files.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.controlGap), files.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Layout.controlGap), files.bottomAnchor.constraint(equalTo: bottomAnchor),
            changes.leadingAnchor.constraint(equalTo: files.trailingAnchor, constant: 4), changes.topAnchor.constraint(equalTo: files.topAnchor), changes.bottomAnchor.constraint(equalTo: files.bottomAnchor),
            search.leadingAnchor.constraint(equalTo: changes.trailingAnchor, constant: 4), search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.controlGap), search.topAnchor.constraint(equalTo: files.topAnchor), search.bottomAnchor.constraint(equalTo: files.bottomAnchor),
            changesIndicator.widthAnchor.constraint(equalToConstant: 5), changesIndicator.heightAnchor.constraint(equalToConstant: 5),
            changesIndicator.leadingAnchor.constraint(equalTo: changes.titleView.trailingAnchor, constant: 3),
            changesIndicator.centerYAnchor.constraint(equalTo: changes.titleView.topAnchor, constant: 1)
        ] + equalWidths)
        select(changes: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(changes selected: Bool?) {
        for (button, active) in [(files, selected == false), (changes, selected == true), (search, selected == nil)] {
            button.isSelected = active
            button.setAccessibilityValue(active ? 1 : 0)
        }
        updateIndicator()
    }

    func updateChanges(count: Int) {
        changeCount = count
        changes.toolTip = "Changes (⌘2) · \(count) files"
        changes.setAccessibilityHelp(count > 0 ? "\(count) Git changes" : "No Git changes")
        updateIndicator()
    }

    private func updateIndicator() {
        changesIndicator.isHidden = changeCount == 0 || changes.isSelected
    }
}

final class WorkspaceStatus: NSView {
    let modeButton = StatusModeButton(title: "Read Only", target: nil, action: nil)
    let message = Theme.label("Open a folder to begin", size: 11, color: Theme.muted)
    let language = Theme.label("", size: 11, color: Theme.muted)
    let modeBackground = NSView()
    private var pointerAreas: [NSTrackingArea] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        modeBackground.wantsLayer = true
        modeBackground.layer?.cornerRadius = 4
        Theme.setLayerColor(Theme.hover, on: modeBackground.layer)
        modeBackground.isHidden = true
        modeBackground.setAccessibilityElement(false)
        modeButton.isBordered = false
        modeButton.alignment = .center
        modeButton.bezelStyle = .inline
        modeButton.controlSize = .small
        modeButton.font = .systemFont(ofSize: 11)
        modeButton.imagePosition = .imageLeading
        modeButton.imageHugsTitle = true
        modeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        modeButton.isEnabled = false
        (modeButton.cell as? NSButtonCell)?.imageDimsWhenDisabled = false
        modeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.lineBreakMode = .byTruncatingTail
        setEditable(false)
        add(modeBackground, modeButton, message, language)
        NSLayoutConstraint.activate([
            modeBackground.leadingAnchor.constraint(equalTo: modeButton.leadingAnchor), modeBackground.trailingAnchor.constraint(equalTo: modeButton.trailingAnchor), modeBackground.topAnchor.constraint(equalTo: modeButton.topAnchor), modeBackground.bottomAnchor.constraint(equalTo: modeButton.bottomAnchor),
            modeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), modeButton.heightAnchor.constraint(equalToConstant: 24), modeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(equalTo: modeButton.trailingAnchor, constant: Theme.Layout.controlGap), message.centerYAnchor.constraint(equalTo: centerYAnchor),
            language.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), language.centerYAnchor.constraint(equalTo: centerYAnchor), language.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: Theme.Layout.inset)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func layout() {
        super.layout()
        refreshModePointer()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in pointerAreas { removeTrackingArea(area) }
        pointerAreas = [
            NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self),
            NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        ]
        for area in pointerAreas { addTrackingArea(area) }
    }
    private var modePointerRect: NSRect {
        guard modeButton.isEnabled, !modeButton.isHiddenOrHasHiddenAncestor else { return .zero }
        return convert(modeButton.bounds.intersection(modeButton.visibleRect), from: modeButton).intersection(bounds.intersection(visibleRect))
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let rect = modePointerRect
        if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
    }
    override func mouseEntered(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { modeBackground.isHidden = true }
    override func cursorUpdate(with event: NSEvent) { updateCursor(at: event.locationInWindow) }
    private func updateCursor(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        guard !isHiddenOrHasHiddenAncestor, bounds.intersection(visibleRect).contains(point) else { modeBackground.isHidden = true; return }
        let interactive = modePointerRect.contains(point)
        modeBackground.isHidden = !interactive
        (interactive ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    private func refreshModePointer() {
        window?.invalidateCursorRects(for: self)
        // Layout in a background window must not replace another window's cursor.
        if containsVisibleWindowMouse, let window { updateCursor(at: window.mouseLocationOutsideOfEventStream) }
        else { modeBackground.isHidden = true }
    }
    func setModeEnabled(_ enabled: Bool) {
        modeButton.isEnabled = enabled
        refreshModePointer()
    }
    func setEditable(_ editable: Bool) {
        modeButton.title = editable ? "Editable" : "Read Only"
        modeButton.attributedTitle = NSAttributedString(string: modeButton.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.muted])
        modeButton.image = NSImage(systemSymbolName: editable ? "pencil" : "lock", accessibilityDescription: nil)
        modeButton.contentTintColor = Theme.muted
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }
}

final class StatusModeButton: PointingHandButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 16, height: size.height)
    }
}
