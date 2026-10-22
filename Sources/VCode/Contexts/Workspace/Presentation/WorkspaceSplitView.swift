import AppKit

final class WorkspaceSplitView: NSSplitView {
    static let minimumSidebarWidth: CGFloat = 220
    static let minimumEditorWidth: CGFloat = 220
    private var resizeTracking: NSTrackingArea?
    private(set) var isResizeHovered = false { didSet { if oldValue != isResizeHovered { needsDisplay = true } } }
    private(set) var isResizing = false { didSet { if oldValue != isResizing { needsDisplay = true } } }

    override var dividerThickness: CGFloat { Theme.Layout.moduleGap }
    override var dividerColor: NSColor { Theme.canvas }

    private var dividerRect: NSRect {
        guard arrangedSubviews.count == 2 else { return .zero }
        return NSRect(x: arrangedSubviews[0].frame.maxX, y: bounds.minY, width: dividerThickness, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let resizeTracking { removeTrackingArea(resizeTracking) }
        let rect = dividerRect.intersection(visibleRect)
        guard !rect.isEmpty else { resizeTracking = nil; isResizeHovered = false; return }
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area)
        resizeTracking = area
        isResizeHovered = window.map { $0.isKeyWindow && rect.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        if isResizeHovered || isResizing { NSCursor.resizeLeftRight.set() }
    }

    override func mouseEntered(with event: NSEvent) {
        isResizeHovered = true
        NSCursor.resizeLeftRight.set()
    }
    override func mouseExited(with event: NSEvent) { isResizeHovered = false }

    override func cursorUpdate(with event: NSEvent) {
        // NSSplitView's default cursor becomes one-sided at a size limit.
        // Keep the same two-way affordance across the whole travel range.
        if isResizing || dividerRect.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.resizeLeftRight.set()
        } else { super.cursorUpdate(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if isResizing || dividerRect.contains(convert(event.locationInWindow, from: nil)) {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard dividerRect.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        isResizing = true
        NSCursor.resizeLeftRight.set()
        displayIfNeeded()
        defer {
            isResizing = false
            updateTrackingAreas()
        }
        // AppKit owns tracking, constraints, cursor feedback and release handling.
        super.mouseDown(with: event)
    }

    override func drawDivider(in rect: NSRect) {
        super.drawDivider(in: rect)
        guard isResizeHovered || isResizing else { return }
        let indicator = NSRect(x: rect.midX - 2, y: rect.minY, width: 4, height: rect.height)
        Theme.accent.withAlphaComponent(isResizing ? 1 : 0.9).setFill()
        NSBezierPath(roundedRect: indicator, xRadius: 2, yRadius: 2).fill()
    }
}
