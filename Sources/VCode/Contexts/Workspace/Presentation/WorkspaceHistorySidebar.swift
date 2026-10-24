import AppKit

final class WorkspaceHistorySidebar: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case project(RecentProject), workspace(RecentWorkspace) }
    static let compactThreshold: CGFloat = 160
    var onChoose: ((URL) -> Void)?
    var onRemove: ((URL) -> Void)?
    var onClear: (() -> Void)?
    var onInteract: (() -> Void)?
    let filter = Theme.searchField()
    let table = HistoryTableView()
    let details = RecentWorkspaceHover()
    let clearButton = Theme.button("trash", tooltip: "Clear all recent projects and worktrees", target: nil, action: nil)
    private let heading = Theme.label("Recent", size: 13, weight: .semibold)
    private let scroll = NSScrollView()
    private let empty = Theme.label("No recent projects", size: 11, color: Theme.muted)
    private var entries: [RecentWorkspace]
    private var current: URL?
    private let available: (URL) -> Bool
    private var scrollLeading: NSLayoutConstraint!
    private var scrollTrailing: NSLayoutConstraint!
    private var filterHeight: NSLayoutConstraint!
    private var filterTop: NSLayoutConstraint!
    private var clearTrailing: NSLayoutConstraint!
    private var clearCenter: NSLayoutConstraint!
    private var headingConstraints: [NSLayoutConstraint] = []
    private var busy = false
    private(set) var isCompact = false
    private(set) var rows: [Row] = []

    init(entries: [RecentWorkspace], current: URL?, available: @escaping (URL) -> Bool) {
        self.entries = entries; self.current = current; self.available = available
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        view.setAccessibilityLabel("Recent projects and worktrees")
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.target = self; clearButton.action = #selector(clearAll)
        clearButton.setAccessibilityLabel("Clear all recent projects and worktrees")
        filter.placeholderString = "Filter recent"
        filter.font = .systemFont(ofSize: 12)
        filter.sendsSearchStringImmediately = true
        filter.sendsWholeSearchString = false
        filter.target = self; filter.action = #selector(filterChanged); filter.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.minWidth = 0
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.headerView = nil; table.backgroundColor = .clear
        table.style = .plain
        table.floatsGroupRows = false
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(choose)
        table.canPointToRow = { [weak self] row in
            guard let self, self.rows.indices.contains(row), case .workspace(let entry) = self.rows[row] else { return false }
            return self.available(entry.root)
        }
        table.focusRingType = .none
        table.setAccessibilityLabel("Recent workspaces")
        scroll.documentView = table; scroll.hasVerticalScroller = false; scroll.hasHorizontalScroller = false
        Theme.compactScrollers(scroll)
        scroll.autohidesScrollers = true; scroll.drawsBackground = false
        empty.alignment = .center
        empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.add(heading, clearButton, filter, scroll, empty)
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4)
        scrollTrailing = scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4)
        filterHeight = filter.heightAnchor.constraint(equalToConstant: 28)
        filterTop = filter.topAnchor.constraint(equalTo: view.topAnchor, constant: 44)
        clearTrailing = clearButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        clearCenter = clearButton.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        headingConstraints = [
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -4)
        ]
        NSLayoutConstraint.activate([
            clearTrailing, clearButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), clearButton.heightAnchor.constraint(equalToConstant: 28), clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            filterTop, filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), filterHeight,
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8), scrollLeading, scrollTrailing, scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 2), empty.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -2), empty.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 16)
        ] + headingConstraints)
        setCompact(view.bounds.width < Self.compactThreshold)
        applyFilter()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let compact = view.bounds.width < Self.compactThreshold
        if compact != isCompact { setCompact(compact); applyFilter() }
        scroll.layoutSubtreeIfNeeded()
        if let column = table.tableColumns.first, scroll.contentSize.width > 0 {
            column.width = scroll.contentSize.width
            table.setFrameSize(NSSize(width: scroll.contentSize.width, height: table.frame.height))
        }
        Theme.compactScrollers(scroll)
    }

    private func setCompact(_ compact: Bool) {
        isCompact = compact
        scrollLeading.constant = compact ? 0 : 4
        scrollTrailing.constant = compact ? 0 : -4
        details.dismiss()
        Theme.rounded(view, color: compact ? .clear : Theme.background)
        heading.isHidden = compact; heading.stringValue = compact ? "" : "Recent"
        if compact { NSLayoutConstraint.deactivate(headingConstraints) }
        else { NSLayoutConstraint.activate(headingConstraints) }
        filter.isHidden = compact; filterHeight.constant = compact ? 0 : 28
        filterTop.constant = compact ? 0 : 44
        clearButton.isHidden = compact
        if compact { filter.stringValue = "" }
        clearTrailing.isActive = !compact; clearCenter.isActive = compact
        clearButton.title = compact ? "" : "Clear All"
        clearButton.imagePosition = compact ? .imageOnly : .noImage
    }

    private func applyFilter() {
        details.dismiss()
        let offset = scroll.contentView.bounds.origin
        rows = RecentProject.group(entries, matching: filter.stringValue).flatMap {
            (isCompact ? [] : [.project($0)]) + $0.workspaces.map { .workspace($0) }
        }
        table.reloadData()
        table.deselectAll(nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(offset.y, max(0, table.bounds.height - scroll.contentSize.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        empty.isHidden = !rows.isEmpty
        empty.stringValue = isCompact ? "—" : filter.stringValue.isEmpty ? "No recent projects" : "No matches"
        empty.toolTip = filter.stringValue.isEmpty ? "No recent projects or worktrees" : "No matching projects or worktrees"
        clearButton.isEnabled = !busy && !entries.isEmpty
        view.needsLayout = true
    }

    func update(entries: [RecentWorkspace], current: URL?) {
        guard self.entries != entries || self.current != current else { return }
        self.entries = entries; self.current = current
        if entries.isEmpty { filter.stringValue = "" }
        applyFilter()
    }

    func setBusy(_ busy: Bool) {
        guard self.busy != busy else { return }
        self.busy = busy; table.isEnabled = !busy; filter.isEnabled = !busy
        applyFilter()
    }

    @objc private func clearAll() { onInteract?(); onClear?() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .project = rows[row] { return 26 }
        return isCompact ? 44 : 56
    }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .project = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .workspace(let entry) = rows[row] { return !busy && entry.root != current && available(entry.root) }
        return false
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SelectionRowView()
        view.backgroundHorizontalInset = isCompact ? 0 : 1
        view.cursorHandledByTable = true
        if case .workspace(let entry) = rows[row] { view.isCurrent = entry.root == current }
        return view
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .project(let project):
            let label = Theme.label("  " + project.root.lastPathComponent, size: 10, color: Theme.muted, weight: .semibold)
            label.toolTip = project.root.path
            return label
        case .workspace(let entry):
            let cell = HistoryCell()
            cell.configure(entry, compact: isCompact, current: entry.root == current, available: available(entry.root))
            cell.onHover = { [weak self] anchor in
                guard let self, self.isCompact, !self.busy else { return }
                self.details.schedule(entry, current: entry.root == self.current, available: self.available(entry.root), beside: anchor) { [weak self] in self?.onInteract?() }
            }
            cell.onHoverExit = { [weak self] in self?.details.leave() }
            cell.removeButton.isEnabled = !busy
            cell.onRemove = { [weak self] in self?.onInteract?(); self?.onRemove?(entry.root) }
            return cell
        }
    }
    @objc private func filterChanged() { onInteract?(); applyFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { view.window?.makeFirstResponder(nil); return true }
        guard commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let index = rows.indices.first(where: { tableView(table, shouldSelectRow: $0) }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { choose() }
            else { view.window?.makeFirstResponder(table) }
        }
        return true
    }
    @objc private func choose() {
        guard table.isEnabled, rows.indices.contains(table.selectedRow), case .workspace(let entry) = rows[table.selectedRow], entry.root != current, available(entry.root) else { return }
        onInteract?(); onChoose?(entry.root)
    }
}

final class HistoryTableView: NSTableView {
    // Current workspace navigation keeps its hand without selecting/reopening it.
    var canPointToRow: ((Int) -> Bool)?
    private var pointerTracking: NSTrackingArea?
    private var cursorTracking: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { window?.invalidateCursorRects(for: self); refreshPointerAtCurrentLocation() }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        // Match the file tree: first entry also works before window activation.
        // AppKit does not permit cursorUpdate with activeAlways.
        let pointer = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        let cursor = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(pointer); pointerTracking = pointer
        addTrackingArea(cursor); cursorTracking = cursor
        window?.invalidateCursorRects(for: self)
        refreshPointerAtCurrentLocation()
    }
    private func hasPointerAction(_ row: Int) -> Bool {
        guard isEnabled, row >= 0, row < numberOfRows, action != nil,
              delegate?.tableView?(self, isGroupRow: row) != true else { return false }
        return canPointToRow?(row) ?? (delegate?.tableView?(self, shouldSelectRow: row) != false)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return }
        let range = rows(in: visibleRect)
        guard range.location != NSNotFound else { return }
        for row in range.location..<NSMaxRange(range) where hasPointerAction(row) {
            let rect = rect(ofRow: row).intersection(visibleRect)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
        }
    }
    private func refreshPointerAtCurrentLocation() {
        guard let window, window.isKeyWindow else { return }
        updatePointer(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
    private func updatePointer(at point: NSPoint) {
        guard !isHiddenOrHasHiddenAncestor, visibleRect.contains(point) else { return }
        // Expanded cleanup remains clickable even on the current/unavailable row.
        var hit = hitTest(convert(point, to: superview))
        while let view = hit, view !== self {
            if let button = view as? NSButton {
                (isEnabled && button.isEnabled ? NSCursor.pointingHand : .arrow).set()
                return
            }
            hit = view.superview
        }
        (hasPointerAction(row(at: point)) ? NSCursor.pointingHand : .arrow).set()
    }
    override func mouseEntered(with event: NSEvent) { updatePointer(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }
    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        updatePointer(at: convert(event.locationInWindow, from: nil))
    }
    override func reloadData() {
        super.reloadData()
        window?.invalidateCursorRects(for: self)
        refreshPointerAtCurrentLocation()
    }
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard isEnabled, row >= 0, delegate?.tableView?(self, shouldSelectRow: row) != false else { return }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { if let action { NSApp.sendAction(action, to: target, from: self) } }
        else { super.keyDown(with: event) }
    }
}

final class HistoryCell: NSTableCellView {
    let title = Theme.label("", size: 12, weight: .medium)
    let path = Theme.label("", size: 10, color: Theme.muted)
    let removeButton = Theme.button("xmark", tooltip: "Remove from Recent", target: nil, action: nil)
    var onRemove: (() -> Void)?
    var onHover: ((HistoryCell) -> Void)?
    var onHoverExit: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var fullConstraints: [NSLayoutConstraint] = []
    private var compactConstraints: [NSLayoutConstraint] = []
    private var isCompact = false
    private var repositoryName = ""
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingMiddle; path.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        removeButton.target = self; removeButton.action = #selector(removeRecent)
        add(title, path, removeButton)
        fullConstraints = [
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), title.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -4), title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor), path.trailingAnchor.constraint(equalTo: title.trailingAnchor), path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4), removeButton.centerYAnchor.constraint(equalTo: centerYAnchor), removeButton.widthAnchor.constraint(equalToConstant: 24), removeButton.heightAnchor.constraint(equalToConstant: 24)
        ]
        compactConstraints = [
            title.centerXAnchor.constraint(equalTo: centerXAnchor), title.centerYAnchor.constraint(equalTo: centerYAnchor), title.widthAnchor.constraint(equalTo: widthAnchor, constant: -8), title.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, constant: -8),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1), removeButton.topAnchor.constraint(equalTo: topAnchor, constant: 1), removeButton.widthAnchor.constraint(equalToConstant: 14), removeButton.heightAnchor.constraint(equalToConstant: 14)
        ]
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ entry: RecentWorkspace, compact: Bool, current: Bool, available: Bool) {
        isCompact = compact
        NSLayoutConstraint.deactivate(compact ? fullConstraints : compactConstraints)
        NSLayoutConstraint.activate(compact ? compactConstraints : fullConstraints)
        let name = entry.root.lastPathComponent
        repositoryName = entry.projectName
        title.stringValue = compact ? entry.projectName : name
        title.font = .systemFont(ofSize: compact ? 9 : 12, weight: current ? .semibold : .medium)
        title.maximumNumberOfLines = compact ? 2 : 1
        title.lineBreakMode = compact ? .byTruncatingTail : .byTruncatingMiddle
        title.alignment = compact ? .center : .left
        (title.cell as? NSTextFieldCell)?.usesSingleLineMode = !compact
        title.preferredMaxLayoutWidth = compact ? max(1, bounds.width - 8) : 0
        title.invalidateIntrinsicContentSize()
        updateCompactTitle()
        let inactiveColor = compact ? Theme.muted : Theme.text
        title.textColor = current ? Theme.accent : available ? inactiveColor : Theme.muted.withAlphaComponent(compact ? 0.65 : 1)
        path.stringValue = (entry.branch ?? "Folder") + " · " + entry.root.path
        path.isHidden = compact
        let state = current ? "Current" : available ? "" : "Unavailable"
        let detail = [entry.projectName, name, entry.branch ?? "Folder", entry.root.path, state].filter { !$0.isEmpty }.joined(separator: "\n")
        for item in [self, title, path] { item.toolTip = compact ? nil : detail }
        removeButton.isHidden = compact
        setAccessibilityLabel(detail)
        removeButton.toolTip = "Remove from Recent: " + entry.root.path
        removeButton.setAccessibilityLabel("Remove from Recent: " + entry.root.path)
        removeButton.feedbackRadius = compact ? 3 : Theme.Layout.controlRadius
        wantsLayer = true; layer?.backgroundColor = NSColor.clear.cgColor
    }
    override func layout() {
        updateCompactTitle()
        super.layout()
    }
    private func updateCompactTitle() {
        guard isCompact, let font = title.font else { return }
        let width = max(1, bounds.width - 8)
        let value = CompactWorkspaceName.text(repositoryName, font: font, width: max(1, width - 4))
        if title.preferredMaxLayoutWidth != width || title.stringValue != value {
            title.preferredMaxLayoutWidth = width
            title.stringValue = value
            title.invalidateIntrinsicContentSize()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { onHover?(self) }
    override func mouseExited(with event: NSEvent) { onHoverExit?() }
    @objc private func removeRecent() { onRemove?() }
}
