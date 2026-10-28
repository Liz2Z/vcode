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
    static let preferredWidth: CGFloat = 45
    static let outerInset: CGFloat = 6
    private(set) var marks: [DiffOverviewMark] = []
    private(set) var occurrenceRows: [Int] = []
    private(set) var searchRows: [Int] = []
    private(set) var currentSearchRows: [Int] = []
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
        Theme.rounded(self, radius: max(0, Theme.Layout.panelRadius - Self.outerInset))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Diff overview")
        setAccessibilityHelp("Red: deleted lines. Green: added lines. Click or drag to scroll both versions.")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
        toolTip = "Diff overview · Click or drag to navigate"
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(rows: [DiffRow], isDiff: Bool = true) {
        marks = DiffOverviewMark.make(rows)
        occurrenceRows = []
        searchRows = []; currentSearchRows = []
        dragOffset = nil
        setAccessibilityLabel(isDiff ? "Diff overview" : "Code overview")
        setAccessibilityHelp("Yellow: highlighted symbol occurrences. Cyan: search matches. " + (isDiff ? "Red: deleted lines. Green: added lines. " : "") + "Click or drag to scroll.")
        toolTip = isDiff ? "Diff overview · Yellow: symbol occurrences · Cyan: search matches · Red/green: Git changes" : "Code overview · Yellow: symbol occurrences · Cyan: search matches"
        needsDisplay = true
    }

    func showOccurrences(rows: [Int]) {
        occurrenceRows = Array(Set(rows.filter { $0 >= 0 })).sorted()
        needsDisplay = true
    }
    func showSearch(rows: [Int], currentRows: [Int]) {
        searchRows = Array(Set(rows.filter { $0 >= 0 })).sorted()
        let matches = Set(searchRows)
        currentSearchRows = Array(Set(currentRows.filter { matches.contains($0) })).sorted()
        needsDisplay = true
    }
    func update(documentHeight: CGFloat, visibleHeight: CGFloat, scrollY: CGFloat) {
        self.documentHeight = max(1, documentHeight)
        self.visibleHeight = max(0, visibleHeight)
        self.scrollY = max(0, min(scrollY, maximumScroll))
        needsDisplay = true
    }
    private var maximumScroll: CGFloat { max(0, documentHeight - visibleHeight) }
    private var track: NSRect { bounds.insetBy(dx: 1, dy: 2) }
    var viewportRect: NSRect {
        let height = maximumScroll == 0 ? track.height / 2 : min(track.height, max(80, track.height * min(1, visibleHeight / documentHeight)))
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
        Theme.surface.withAlphaComponent(0.28).setFill()
        bounds.intersection(dirtyRect).fill()
        Theme.text.withAlphaComponent(dragOffset != nil ? 0.40 : hovered ? 0.32 : 0.24).setFill()
        NSBezierPath(roundedRect: viewportRect, xRadius: Theme.Layout.controlRadius, yRadius: Theme.Layout.controlRadius).fill()
        // Marker thickness is independent of the wider navigation hit target.
        let laneWidth: CGFloat = 4
        let diffLeft = track.maxX - laneWidth * 2 - 1
        for mark in marks {
            let stripe = markerRect(rows: mark.rows)
            let rect = NSRect(x: mark.removed ? diffLeft : diffLeft + laneWidth,
                              y: stripe.minY, width: laneWidth, height: stripe.height)
            (mark.removed ? Theme.red : Theme.green).setFill()
            rect.fill()
        }
        // Search has its own left lane; it never overwrites semantic yellow.
        for (rows, color) in [(searchRows, Theme.searchMatch), (currentSearchRows, Theme.currentSearchMatch)] {
            color.setFill()
            for row in rows {
                let stripe = markerRect(rows: row..<(row + 1))
                NSRect(x: track.minX + 1, y: stripe.minY, width: laneWidth, height: stripe.height).fill()
            }
        }
        Theme.occurrence.setFill()
        for row in occurrenceRows {
            let stripe = markerRect(rows: row..<(row + 1))
            NSRect(x: track.midX - laneWidth / 2, y: stripe.minY, width: laneWidth, height: stripe.height).fill()
        }
    }

    private func markerRect(rows: Range<Int>) -> NSRect {
        let y = min(track.maxY - 3, track.minY + (Theme.Code.verticalInset + CGFloat(rows.lowerBound) * Theme.Code.lineHeight) / documentHeight * track.height)
        let height = max(3, CGFloat(rows.count) * Theme.Code.lineHeight / documentHeight * track.height)
        return NSRect(x: track.minX, y: y, width: track.width, height: min(height, track.maxY - y))
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
