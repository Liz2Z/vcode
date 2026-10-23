import AppKit

final class SelectionRowView: NSTableRowView {
    var isHovered = false { didSet { needsDisplay = true } }
    var isPressed = false { didSet { needsDisplay = true } }
    var isActionEnabled = true { didSet { window?.invalidateCursorRects(for: self) } }
    private var tracking: NSTrackingArea?

    private var owningTable: NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView { return table }
            ancestor = view.superview
        }
        return nil
    }

    var hasClickAction: Bool {
        guard isActionEnabled, !isHiddenOrHasHiddenAncestor, let table = owningTable else { return false }
        let row = table.row(for: self)
        guard table.isEnabled, row >= 0, row < table.numberOfRows else { return false }
        // Outline sections are expandable, unlike static result headings.
        if table is NSOutlineView { return true }
        return table.delegate?.tableView?(table, isGroupRow: row) != true
            && table.delegate?.tableView?(table, shouldSelectRow: row) != false
            && (table.action != nil || table.doubleAction != nil)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // FileOutlineView owns its complete row width and hover events.
        if !(owningTable is NSOutlineView), hasClickAction, !visibleRect.isEmpty {
            addCursorRect(visibleRect, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        window?.invalidateCursorRects(for: self)
        if let window { isHovered = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func prepareForReuse() { super.prepareForReuse(); isHovered = false; isPressed = false; isActionEnabled = true }

    private func fill(_ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if !isSelected {
            if isPressed { fill(Theme.accent.withAlphaComponent(0.32)) }
            else if isHovered { fill(NSColor.white.withAlphaComponent(0.09)) }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        fill(Theme.accent.withAlphaComponent(isPressed ? 0.34 : isHovered ? 0.27 : isEmphasized ? 0.20 : 0.13))
    }
}

extension NSTableView {
    func invalidateRowCursorRects() {
        enumerateAvailableRowViews { row, _ in row.window?.invalidateCursorRects(for: row) }
    }
}
