import AppKit

final class FileOutlineView: NSOutlineView {
    override var isEnabled: Bool {
        didSet {
            enumerateAvailableRowViews { _, row in
                guard let cell = self.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { return }
                cell.updateIndexAvailability(outlineEnabled: self.isEnabled)
            }
            window?.invalidateCursorRects(for: self)
            refreshPointerAtCurrentLocation()
        }
    }
    private(set) var isHandlingMouse = false
    private var pressedNode: FileNode?
    private var pressedRow = -1
    private var hoveredRow = -1
    private var pointerTracking: NSTrackingArea?
    private var cursorTracking: NSTrackingArea?

    /// NSTableView normally handles whole-row mouse tracking. Route the explicit
    /// action control first so a click never also selects a file or folds a folder.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else { return nil }
        let local = convert(point, from: superview)
        return indexButton(at: local) ?? hit
    }

    private func indexButton(at point: NSPoint) -> NSButton? {
        let row = self.row(at: point)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell,
              !cell.indexButton.isHidden,
              cell.indexButton.bounds.contains(cell.indexButton.convert(point, from: self)) else { return nil }
        return cell.indexButton
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        // Hover must work before the first activating click. AppKit does not
        // support cursorUpdate with activeAlways, so keep separate areas.
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        pointerTracking = area
        let cursorArea = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(cursorArea)
        cursorTracking = cursorArea
        window?.invalidateCursorRects(for: self)
        refreshPointerAtCurrentLocation()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isEnabled, !isHiddenOrHasHiddenAncestor else { return }
        let range = rows(in: visibleRect)
        guard range.location != NSNotFound else { return }
        for row in range.location..<NSMaxRange(range) where item(atRow: row) is FileNode {
            let rect = rect(ofRow: row).intersection(visibleRect)
            if !rect.isEmpty { addCursorRect(rect, cursor: .pointingHand) }
            if let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell, !cell.indexButton.isHidden, !cell.indexButton.isEnabled {
                addCursorRect(cell.indexButton.convert(cell.indexButton.bounds, to: self).intersection(visibleRect), cursor: .arrow)
            }
        }
    }

    private func refreshPointerAtCurrentLocation() {
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        updateHover(at: point)
        updatePointerCursor(at: point)
    }

    override func layout() {
        super.layout()
        refreshPointerAtCurrentLocation()
    }

    private func updatePointerCursor(at point: NSPoint) {
        // The outline owns hover dispatch, including disclosure controls and
        // section rows. Do not wait for a row view to be activated by a click.
        guard !isHiddenOrHasHiddenAncestor, visibleRect.contains(point) else { return }
        let row = row(at: point)
        let clickable = isEnabled && row >= 0 && item(atRow: row) is FileNode && indexButton(at: point)?.isEnabled != false
        (clickable ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        updatePointerCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateHover(_ event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    private func setRowHovered(_ hovered: Bool, row: Int) {
        guard row >= 0 else { return }
        (rowView(atRow: row, makeIfNecessary: false) as? SelectionRowView)?.isHovered = hovered
        (view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell)?.setRowHovered(hovered)
    }

    private func updateHover(at point: NSPoint) {
        let next = visibleRect.contains(point) ? row(at: point) : -1
        if next != hoveredRow { setRowHovered(false, row: hoveredRow); hoveredRow = next }
        setRowHovered(true, row: next)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(event)
        updatePointerCursor(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        updateHover(event)
        updatePointerCursor(at: convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) {
        setRowHovered(false, row: hoveredRow)
        hoveredRow = -1
    }

    override func mouseDown(with event: NSEvent) {
        cancelPress()
        guard isEnabled else { return }
        updateHover(event)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? FileNode else { super.mouseDown(with: event); return }
        pressedNode = node
        pressedRow = row
        let feedback = rowView(atRow: row, makeIfNecessary: false) as? SelectionRowView
        feedback?.isPressed = true
        feedback?.displayIfNeeded()
        // Use the same explicit row interaction for files and folders. After
        // reload/expansion AppKit's mouse tracking can return without selecting
        // a rebuilt file row; don't depend on its cached clicked-row state.
        isHandlingMouse = true
        defer { isHandlingMouse = false }
        window?.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    override func mouseDragged(with event: NSEvent) {
        updateHover(event)
        guard pressedNode != nil else { super.mouseDragged(with: event); return }
        let inside = row(at: convert(event.locationInWindow, from: nil)) == pressedRow
        (rowView(atRow: pressedRow, makeIfNecessary: false) as? SelectionRowView)?.isPressed = inside
    }

    override func mouseUp(with event: NSEvent) {
        updateHover(event)
        guard let node = pressedNode else { super.mouseUp(with: event); return }
        let inside = row(at: convert(event.locationInWindow, from: nil)) == pressedRow
            && item(atRow: pressedRow) as? FileNode === node
            && selectedRow == pressedRow
        cancelPress()
        guard inside else { return }
        if node.directory {
            if isItemExpanded(node) { collapseItem(node) } else { expandItem(node) }
        } else { _ = sendAction(action, to: target) }
    }

    override func reloadData() {
        cancelPress()
        setRowHovered(false, row: hoveredRow)
        hoveredRow = -1
        super.reloadData()
        window?.invalidateCursorRects(for: self)
    }

    private func cancelPress() {
        if pressedRow >= 0 { (rowView(atRow: pressedRow, makeIfNecessary: false) as? SelectionRowView)?.isPressed = false }
        pressedNode = nil
        pressedRow = -1
    }
}
