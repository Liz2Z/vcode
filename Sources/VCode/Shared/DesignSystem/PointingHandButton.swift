import AppKit

// Cursor rectangles are clipped and retired by AppKit when views scroll or hide.
// Avoid setting a global cursor on mouse exit: the next view owns that decision.
class PointingHandButton: NSButton {
    override var isEnabled: Bool {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled, !isHiddenOrHasHiddenAncestor, !visibleRect.isEmpty {
            addCursorRect(visibleRect, cursor: .pointingHand)
        }
    }
}
