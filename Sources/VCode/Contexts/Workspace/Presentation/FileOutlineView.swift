import AppKit

final class FileOutlineView: NSOutlineView {
    private(set) var isHandlingMouse = false
    private var pressedNode: FileNode?
    private var pressedRow = -1
    private var hoveredRow = -1
    private var pointerTracking: NSTrackingArea?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    private func updateHover(_ event: NSEvent) {
        let next = row(at: convert(event.locationInWindow, from: nil))
        if next != hoveredRow {
            if hoveredRow >= 0 { (rowView(atRow: hoveredRow, makeIfNecessary: false) as? SelectionRowView)?.isHovered = false }
            hoveredRow = next
        }
        if next >= 0 { (rowView(atRow: next, makeIfNecessary: true) as? SelectionRowView)?.isHovered = true }
    }

    override func mouseMoved(with event: NSEvent) { super.mouseMoved(with: event); updateHover(event) }
    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) {
        if hoveredRow >= 0 { (rowView(atRow: hoveredRow, makeIfNecessary: false) as? SelectionRowView)?.isHovered = false }
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
        if hoveredRow >= 0 { (rowView(atRow: hoveredRow, makeIfNecessary: false) as? SelectionRowView)?.isHovered = false }
        hoveredRow = -1
        super.reloadData()
    }

    private func cancelPress() {
        if pressedRow >= 0 { (rowView(atRow: pressedRow, makeIfNecessary: false) as? SelectionRowView)?.isPressed = false }
        pressedNode = nil
        pressedRow = -1
    }
}
