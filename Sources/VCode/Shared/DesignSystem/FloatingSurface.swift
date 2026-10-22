import AppKit

// A distinct surface above the workspace, without adding separator lines.
final class FloatingSurface: NSView {
    private let radius: CGFloat = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.fill(self, Theme.floating)
        layer?.cornerRadius = radius
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -6)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
