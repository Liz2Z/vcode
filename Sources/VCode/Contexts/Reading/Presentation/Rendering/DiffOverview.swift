import AppKit

/// Uses aligned diff rows, including placeholders, so both versions share one scale.
struct DiffOverviewMark: Equatable {
    let rows: Range<Int>
    let removed: Bool

    static func make(_ rows: [DiffRow]) -> [Self] {
        var result: [Self] = []
        for removed in [true, false] {
            var start: Int?
            for index in 0...rows.count {
                let changed = index < rows.count && (removed ? rows[index].left.kind == .removed : rows[index].right.kind == .added)
                if changed, start == nil { start = index }
                if !changed, let first = start {
                    result.append(Self(rows: first..<index, removed: removed))
                    start = nil
                }
            }
        }
        return result
    }
}

/// A narrow change overview and draggable viewport, rather than a second code renderer.
final class DiffOverview: NSView {
    private(set) var marks: [DiffOverviewMark] = []
    private(set) var documentHeight: CGFloat = 1
    private(set) var visibleHeight: CGFloat = 1
    private(set) var scrollY: CGFloat = 0
    var onNavigate: ((CGFloat) -> Void)?
    var onWheel: ((NSEvent) -> Void)?
    private var dragOffset: CGFloat?
    private var hovered = false
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Diff overview")
        setAccessibilityHelp("Red: deleted lines. Green: added lines. Click or drag to scroll both versions.")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
        toolTip = "Diff overview · Click or drag to navigate"
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(rows: [DiffRow]) { marks = DiffOverviewMark.make(rows); dragOffset = nil; needsDisplay = true }
    func update(documentHeight: CGFloat, visibleHeight: CGFloat, scrollY: CGFloat) {
        self.documentHeight = max(1, documentHeight)
        self.visibleHeight = max(0, visibleHeight)
        self.scrollY = max(0, min(scrollY, maximumScroll))
        needsDisplay = true
    }
    private var maximumScroll: CGFloat { max(0, documentHeight - visibleHeight) }
    private var track: NSRect { bounds.insetBy(dx: 1, dy: 2) }
    var viewportRect: NSRect {
        let height = min(track.height, max(18, track.height * min(1, visibleHeight / documentHeight)))
        let y = maximumScroll > 0 ? scrollY / maximumScroll * (track.height - height) : 0
        return NSRect(x: track.minX, y: track.minY + y, width: track.width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard track.height > 0, bounds.intersects(dirtyRect) else { return }
        // Since macOS 14 an NSView need not clip its dirty region to bounds.
        // Never let this narrow rail repaint the adjacent code or pane header.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        bounds.clip()
        Theme.background.setFill(); bounds.intersection(dirtyRect).fill()
        Theme.muted.withAlphaComponent(dragOffset != nil ? 0.28 : hovered ? 0.22 : 0.13).setFill()
        NSBezierPath(roundedRect: viewportRect, xRadius: 2, yRadius: 2).fill()
        for mark in marks {
            let y = min(track.maxY - 3, track.minY + (Theme.Code.verticalInset + CGFloat(mark.rows.lowerBound) * Theme.Code.lineHeight) / documentHeight * track.height)
            let height = max(3, CGFloat(mark.rows.count) * Theme.Code.lineHeight / documentHeight * track.height)
            let laneWidth = max(1, (track.width - 3) / 2)
            let rect = NSRect(x: mark.removed ? track.minX + 1 : track.maxX - laneWidth - 1,
                              y: y, width: laneWidth, height: min(height, track.maxY - y))
            (mark.removed ? Theme.red : Theme.green).setFill()
            rect.fill()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOffset = viewportRect.contains(point) ? point.y - viewportRect.minY : viewportRect.height / 2
        navigate(y: point.y)
    }
    override func mouseDragged(with event: NSEvent) { navigate(y: convert(event.locationInWindow, from: nil).y) }
    override func mouseUp(with event: NSEvent) { dragOffset = nil; needsDisplay = true }
    private func navigate(y: CGFloat) {
        let travel = track.height - viewportRect.height
        let fraction = travel > 0 ? (y - track.minY - (dragOffset ?? viewportRect.height / 2)) / travel : 0
        onNavigate?(min(1, max(0, fraction)) * maximumScroll)
        needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) { onWheel?(event) }
    override func accessibilityValue() -> Any? { maximumScroll > 0 ? scrollY / maximumScroll : 0 }
    override func setAccessibilityValue(_ value: Any?) {
        guard let number = value as? NSNumber, number.doubleValue.isFinite else { return }
        onNavigate?(CGFloat(min(1, max(0, number.doubleValue))) * maximumScroll)
    }
}
