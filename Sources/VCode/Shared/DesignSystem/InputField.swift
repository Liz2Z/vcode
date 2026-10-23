import AppKit

/// Keep native search editing, buttons and hit testing on the same centered geometry.
final class InputSearchField: NSSearchField {
    override var searchTextBounds: NSRect {
        InputFieldGeometry.center(super.searchTextBounds, in: bounds, font: font)
    }
    override var searchButtonBounds: NSRect {
        InputFieldGeometry.center(super.searchButtonBounds, in: bounds)
    }
    override var cancelButtonBounds: NSRect {
        InputFieldGeometry.center(super.cancelButtonBounds, in: bounds)
    }
}

final class InputTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { InputTextFieldCell.self }
        set { }
    }
}

private final class InputTextFieldCell: NSTextFieldCell {
    // AppKit uses this rectangle for both display and the native field editor.
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        InputFieldGeometry.center(super.drawingRect(forBounds: rect), in: rect, font: font)
    }
}

private enum InputFieldGeometry {
    private static let layout = NSLayoutManager()

    static func center(_ content: NSRect, in bounds: NSRect, font: NSFont? = nil) -> NSRect {
        let height = min(bounds.height, font.map { ceil(layout.defaultLineHeight(for: $0)) } ?? content.height)
        return NSRect(x: content.minX, y: bounds.midY - height / 2, width: content.width, height: height)
    }
}
