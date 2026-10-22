import AppKit

final class SelectionRowView: NSTableRowView {
    var isHovered = false { didSet { needsDisplay = true } }
    var isPressed = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        if let window { isHovered = visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func prepareForReuse() { super.prepareForReuse(); isHovered = false; isPressed = false }

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
