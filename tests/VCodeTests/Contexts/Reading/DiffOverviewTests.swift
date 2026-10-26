import AppKit
import XCTest
@testable import VCode

final class DiffOverviewTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testExpandedDirtyRectCannotPaintOverAdjacentCodeOrHeader() throws {
        let map = DiffOverview(frame: NSRect(x: 0, y: 0, width: 14, height: 100))
        map.update(documentHeight: 1000, visibleHeight: 200, scrollY: 0)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 160, pixelsHigh: 160,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 160).fill()
        // AppKit can supply a dirty region larger than this narrow view.
        // The surrounding pixels represent an already-painted header and code.
        map.draw(NSRect(x: -50, y: -50, width: 250, height: 250))
        context.flushGraphics()
        // Bitmap rows run from top to bottom, while this context draws upward.
        for point in [(80, 50), (7, 10)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: point.0, y: point.1)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
            XCTAssertEqual(color.greenComponent, 0, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, 1, accuracy: 0.01)
        }
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 7, y: 110)).greenComponent, 0.1,
                             "The overview itself must still draw inside its bounds")
    }

    func testMarksKeepDeletedAndAddedLanesAndAlignedPlaceholderRows() {
        let unchanged = CodeLine(number: 1, text: "context", kind: .unchanged)
        let removed = CodeLine(number: 2, text: "old", kind: .removed)
        let added = CodeLine(number: 2, text: "new", kind: .added)
        let blank = CodeLine(number: nil, text: "", kind: .placeholder)
        let rows = [DiffRow(left: unchanged, right: unchanged), DiffRow(left: removed, right: added),
                    DiffRow(left: removed, right: blank), DiffRow(left: blank, right: added),
                    DiffRow(left: unchanged, right: unchanged), DiffRow(left: blank, right: added)]
        XCTAssertEqual(DiffOverviewMark.make(rows), [
            DiffOverviewMark(rows: 1..<3, removed: true), DiffOverviewMark(rows: 1..<2, removed: false),
            DiffOverviewMark(rows: 3..<4, removed: false), DiffOverviewMark(rows: 5..<6, removed: false)])
        XCTAssertTrue(DiffOverviewMark.make([]).isEmpty)
    }

    func testViewportEndpointsAndMinimumGrabSizeOnVeryLongAndShortFiles() {
        let map = DiffOverview(frame: NSRect(x: 0, y: 0, width: 14, height: 500))
        map.update(documentHeight: 1_000_000, visibleHeight: 400, scrollY: 0)
        XCTAssertEqual(map.viewportRect.minY, 2)
        XCTAssertEqual(map.viewportRect.height, 18)
        map.update(documentHeight: 1_000_000, visibleHeight: 400, scrollY: 999_600)
        XCTAssertEqual(map.viewportRect.maxY, 498, accuracy: 0.01)
        map.update(documentHeight: 100, visibleHeight: 400, scrollY: 90)
        XCTAssertEqual(map.viewportRect.height, 496)
        XCTAssertEqual(map.scrollY, 0)
        map.update(documentHeight: 0, visibleHeight: 400, scrollY: 0)
        XCTAssertTrue(map.viewportRect.height.isFinite)
    }

    func testTrackClickDragAndAccessibilityScrollBothVersionsWithoutHorizontalJump() throws {
        let (editor, window, snapshot) = makeEditor()
        defer { withExtendedLifetime(window) {} }
        editor.prepare(path: snapshot.path, diff: true, isGit: true, comparison: .unstaged)
        editor.show(snapshot, diff: true, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        let map = editor.right.diffOverview
        XCTAssertFalse(map.isHidden)
        XCTAssertTrue(editor.left.diffOverview.isHidden)
        XCTAssertFalse(editor.left.scroll.hasVerticalScroller)
        XCTAssertFalse(editor.right.scroll.hasVerticalScroller)
        editor.right.scroll.contentView.scroll(to: NSPoint(x: 180, y: 0))
        let x = editor.right.scroll.contentView.bounds.minX
        func event(_ type: NSEvent.EventType, _ y: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: map.convert(NSPoint(x: 7, y: y), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
        }
        map.mouseDown(with: try event(.leftMouseDown, map.bounds.height * 0.7))
        XCTAssertGreaterThan(editor.right.scroll.contentView.bounds.minY, 3000)
        XCTAssertEqual(editor.left.scroll.contentView.bounds.minY, editor.right.scroll.contentView.bounds.minY, accuracy: 0.5)
        map.mouseDragged(with: try event(.leftMouseDragged, map.bounds.height + 100))
        map.mouseUp(with: try event(.leftMouseUp, map.bounds.height + 100))
        XCTAssertEqual(map.viewportRect.maxY, map.bounds.height - 2, accuracy: 0.5)
        XCTAssertEqual(editor.right.scroll.contentView.bounds.minX, x, accuracy: 0.1)
        map.setAccessibilityValue(0)
        XCTAssertEqual(editor.right.scroll.contentView.bounds.minY, 0, accuracy: 0.5)
        editor.left.scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        XCTAssertEqual(map.scrollY, 2000, accuracy: 0.5)
        XCTAssertEqual(editor.left.scroll.contentView.bounds.minY, editor.right.scroll.contentView.bounds.minY, accuracy: 0.5)
    }

    func testRefreshResizeAndSourceTransitionsClearMarkersAndReclaimSpace() throws {
        let (editor, window, snapshot) = makeEditor()
        defer { withExtendedLifetime(window) {} }
        for diff in [true, false, true, false] {
            editor.prepare(path: snapshot.path, diff: diff, isGit: true, comparison: .unstaged)
            let version = FileSnapshot(path: snapshot.path, before: snapshot.before, after: snapshot.after, rows: snapshot.rows, message: nil, isBinary: false, comparison: diff ? .unstaged : nil)
            editor.show(version, diff: diff, preserveScroll: false)
            for size in [NSSize(width: 1400, height: 600), NSSize(width: 800, height: 400)] {
                window.setContentSize(size)
                editor.layoutSubtreeIfNeeded()
                let pane = editor.right
                XCTAssertEqual(pane.diffOverview.isHidden, !diff)
                XCTAssertEqual(pane.bounds.width - pane.scroll.frame.width, diff ? 14 : 0, accuracy: 0.5)
                XCTAssertEqual(pane.diffOverview.bounds.height, pane.scroll.bounds.height, accuracy: 0.5)
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    pane.appearance = NSAppearance(named: appearance)
                    if let bitmap = pane.bitmapImageRepForCachingDisplay(in: pane.bounds) { pane.cacheDisplay(in: pane.bounds, to: bitmap) }
                }
            }
        }
        editor.prepare(path: "deleted.ts", diff: true, isGit: true, comparison: .staged)
        let removed = snapshot.rows.prefix(3).map { DiffRow(left: CodeLine(number: $0.left.number, text: "deleted", kind: .removed), right: CodeLine(number: nil, text: "", kind: .placeholder)) }
        editor.show(FileSnapshot(path: "deleted.ts", before: "deleted", after: "", rows: removed, message: nil, isBinary: false, comparison: .staged), diff: true, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.right.diffOverview.marks, [DiffOverviewMark(rows: 0..<3, removed: true)])
        XCTAssertEqual(editor.right.diffOverview.documentHeight, max(1, editor.right.text.bounds.height), accuracy: 0.5)
        XCTAssertEqual(editor.right.diffOverview.viewportRect.height, editor.right.diffOverview.bounds.height - 4, accuracy: 0.5)
        editor.reset()
        XCTAssertTrue(editor.right.diffOverview.isHidden)
        XCTAssertTrue(editor.right.diffOverview.marks.isEmpty)
    }

    private func makeEditor() -> (EditorView, NSWindow, FileSnapshot) {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        let rows = (0..<400).map { index in
            DiffRow(left: CodeLine(number: index + 1, text: "const old\(index) = 1; // " + String(repeating: "long ", count: 60), kind: index % 100 == 0 ? .removed : .unchanged),
                    right: CodeLine(number: index + 1, text: "const new\(index) = 2; // " + String(repeating: "long ", count: 60), kind: index % 100 == 0 ? .added : .unchanged))
        }
        return (editor, window, FileSnapshot(path: "long.ts", before: rows.map(\.left.text).joined(separator: "\n"), after: rows.map(\.right.text).joined(separator: "\n"), rows: rows, message: nil, isBinary: false, comparison: .unstaged))
    }
}
