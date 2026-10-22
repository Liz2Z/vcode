import AppKit

final class FileOutlineView: NSOutlineView {
    private(set) var isHandlingMouse = false
    private var pressedFolder: FileNode?
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
        guard isEnabled else { return }
        updateHover(event)
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { super.mouseDown(with: event); return }
        let feedback = rowView(atRow: row, makeIfNecessary: false) as? SelectionRowView
        feedback?.isPressed = true
        feedback?.displayIfNeeded()
        if let node = item(atRow: row) as? FileNode, node.directory {
            pressedFolder = node
            pressedRow = row
            window?.makeFirstResponder(self)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return
        }
        isHandlingMouse = true
        defer { isHandlingMouse = false; feedback?.isPressed = false }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        updateHover(event)
        guard pressedFolder != nil else { super.mouseDragged(with: event); return }
        let inside = row(at: convert(event.locationInWindow, from: nil)) == pressedRow
        (rowView(atRow: pressedRow, makeIfNecessary: false) as? SelectionRowView)?.isPressed = inside
    }

    override func mouseUp(with event: NSEvent) {
        updateHover(event)
        guard let node = pressedFolder else { super.mouseUp(with: event); return }
        let inside = row(at: convert(event.locationInWindow, from: nil)) == pressedRow
        (rowView(atRow: pressedRow, makeIfNecessary: false) as? SelectionRowView)?.isPressed = false
        pressedFolder = nil
        pressedRow = -1
        guard inside else { return }
        if isItemExpanded(node) { collapseItem(node) } else { expandItem(node) }
    }
}
