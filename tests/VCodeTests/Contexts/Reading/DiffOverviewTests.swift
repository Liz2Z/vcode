import AppKit
import XCTest
@testable import VCode

final class DiffOverviewTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testExpandedDirtyRectCannotPaintOverAdjacentCodeOrHeader() throws {
        let map = DiffOverview(frame: NSRect(x: 0, y: 0, width: 60, height: 100))
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
        let map = DiffOverview(frame: NSRect(x: 0, y: 0, width: 60, height: 500))
        map.update(documentHeight: 1_000_000, visibleHeight: 400, scrollY: 0)
        XCTAssertEqual(map.viewportRect.minY, 2)
        XCTAssertEqual(map.viewportRect.height, 80)
        map.update(documentHeight: 1_000_000, visibleHeight: 400, scrollY: 999_600)
        XCTAssertEqual(map.viewportRect.maxY, 498, accuracy: 0.01)
        map.update(documentHeight: 100, visibleHeight: 400, scrollY: 90)
        XCTAssertEqual(map.viewportRect.height, 248)
        XCTAssertEqual(map.viewportRect.minY, 2)
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
                XCTAssertFalse(pane.diffOverview.isHidden)
                XCTAssertFalse(pane.scroll.hasVerticalScroller)
                XCTAssertEqual(pane.diffOverview.frame.width, 45, accuracy: 0.5)
                XCTAssertEqual(pane.diffOverview.frame.minX - pane.scroll.frame.maxX, 6, accuracy: 0.5)
                XCTAssertEqual(pane.bounds.maxX - pane.diffOverview.frame.maxX, 6, accuracy: 0.5)
                XCTAssertEqual(pane.diffOverview.frame.minY - pane.scroll.frame.minY, 6, accuracy: 0.5)
                XCTAssertEqual(pane.scroll.frame.maxY - pane.diffOverview.frame.maxY, 6, accuracy: 0.5)
                if !diff { XCTAssertTrue(pane.diffOverview.marks.isEmpty) }
                XCTAssertEqual(pane.diffOverview.bounds.height, pane.scroll.bounds.height - 12, accuracy: 0.5)
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
        XCTAssertEqual(editor.right.diffOverview.viewportRect.height, (editor.right.diffOverview.bounds.height - 4) / 2, accuracy: 0.5)
        editor.reset()
        XCTAssertTrue(editor.right.diffOverview.isHidden)
        XCTAssertTrue(editor.right.diffOverview.marks.isEmpty)
    }

    func testSemanticOccurrencesFollowDisplayedUTF16RowsAndClearStaleReplies() throws {
        let pane = CodePane()
        let blank = CodeLine(number: nil, text: "", kind: .placeholder)
        let lines = [CodeLine(number: 1, text: "const value = 1;", kind: .unchanged), blank,
                     CodeLine(number: 2, text: "/* 中文😀 */ value + value;", kind: .added),
                     CodeLine(number: 3, text: "// value is only a comment", kind: .unchanged),
                     CodeLine(number: 4, text: "value;", kind: .unchanged)]
        pane.showDiffOverview(lines.map { DiffRow(left: blank, right: $0) })
        pane.show(lines: lines, path: "main.ts", title: "", detail: "")
        let declaration = try XCTUnwrap(pane.characterRange(startLine: 0, startCharacter: 6, endLine: 0, endCharacter: 11))
        let firstUse = try XCTUnwrap(pane.characterRange(startLine: 1, startCharacter: 11, endLine: 1, endCharacter: 16))
        let secondUse = try XCTUnwrap(pane.characterRange(startLine: 1, startCharacter: 19, endLine: 1, endCharacter: 24))
        XCTAssertEqual((pane.text.string as NSString).substring(with: firstUse), "value")
        XCTAssertEqual((pane.text.string as NSString).substring(with: secondUse), "value")
        let lastUse = try XCTUnwrap(pane.characterRange(startLine: 3, startCharacter: 0, endLine: 3, endCharacter: 5))
        var replies: [([NSRange]) -> Void] = []
        pane.text.onSymbolClick = { _, reply in replies.append(reply) }
        pane.text.highlightSymbol(at: declaration.location)
        pane.text.highlightSymbol(at: lastUse.location)
        replies[0]([declaration])
        XCTAssertTrue(pane.diffOverview.occurrenceRows.isEmpty)
        replies[1]([lastUse, secondUse, firstUse, declaration, declaration])
        XCTAssertEqual(pane.diffOverview.occurrenceRows, [0, 2, 4], "Use displayed rows, skip placeholders and deduplicate same-line occurrences")
        XCTAssertEqual(pane.text.occurrenceRanges.count, 4, "The overview must use exactly the semantic ranges, never scan same words in comments")
        pane.text.clearInspectionFeedback()
        XCTAssertEqual(pane.diffOverview.occurrenceRows, [0, 2, 4])
        pane.text.highlightSymbol(at: nil)
        XCTAssertTrue(pane.diffOverview.occurrenceRows.isEmpty)
        pane.text.highlightSymbol(at: declaration.location)
        pane.show(lines: [lines[0]], path: "other.ts", title: "", detail: "")
        replies[2]([declaration])
        XCTAssertTrue(pane.diffOverview.occurrenceRows.isEmpty)
    }

    func testSourceOccurrencesUseSameRailAndRemainIndependentAcrossEditors() throws {
        let (editor, window, snapshot) = makeEditor()
        defer { withExtendedLifetime(window) {} }
        editor.prepare(path: snapshot.path, diff: false, isGit: true)
        let source = FileSnapshot(path: snapshot.path, before: "", after: snapshot.after, rows: [], message: nil, isBinary: false)
        editor.show(source, diff: false, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        let pane = editor.right
        let range = (pane.text.string as NSString).range(of: "new200")
        pane.text.onSymbolClick = { _, reply in reply([range]) }
        pane.text.highlightSymbol(at: range.location)
        XCTAssertEqual(pane.diffOverview.occurrenceRows, [200])
        XCTAssertTrue(pane.diffOverview.marks.isEmpty)
        XCTAssertEqual(pane.diffOverview.accessibilityLabel(), "Code overview")
        pane.diffOverview.setAccessibilityValue(0.5)
        XCTAssertGreaterThan(pane.scroll.contentView.bounds.minY, 1000)
        XCTAssertEqual(pane.diffOverview.occurrenceRows, [200])
        let other = CodePane()
        other.showDiffOverview(nil, source: true)
        other.show(lines: [CodeLine(number: 1, text: "const new200 = 0;", kind: .unchanged)], path: "other.ts", title: "", detail: "")
        XCTAssertTrue(other.diffOverview.occurrenceRows.isEmpty)
        editor.reset()
        XCTAssertTrue(pane.diffOverview.isHidden)
        XCTAssertTrue(pane.diffOverview.occurrenceRows.isEmpty)
    }

    func testOccurrenceLaneRemainsVisibleBesideGitMarkersInBothThemes() throws {
        let map = DiffOverview(frame: NSRect(x: 0, y: 0, width: 60, height: 100))
        let row = DiffRow(left: CodeLine(number: 1, text: "old", kind: .removed), right: CodeLine(number: 1, text: "new", kind: .added))
        map.show(rows: [row])
        map.showOccurrences(rows: [0])
        map.showSearch(rows: [0, 2], currentRows: [2])
        map.update(documentHeight: 100, visibleHeight: 100, scrollY: 0)
        for width in [30, 60, 100] {
        map.setFrameSize(NSSize(width: width, height: 100))
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: theme))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            appearance.performAsCurrentDrawingAppearance { map.draw(map.bounds) }
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            // All three categories occupy the same line but separate columns.
            for (x, expected) in [(width - 8, Theme.red), (width / 2, Theme.occurrence), (width - 4, Theme.green), (3, Theme.searchMatch)] {
                var resolved: NSColor!
                appearance.performAsCurrentDrawingAppearance { resolved = expected.usingColorSpace(.deviceRGB) }
                let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: 83)?.usingColorSpace(.deviceRGB))
                XCTAssertEqual(actual.redComponent, resolved.redComponent, accuracy: 0.02)
                XCTAssertEqual(actual.greenComponent, resolved.greenComponent, accuracy: 0.02)
                XCTAssertEqual(actual.blueComponent, resolved.blueComponent, accuracy: 0.02)
                let matchingPixels = (0..<width).filter { column in
                    guard let color = bitmap.colorAt(x: column, y: 83)?.usingColorSpace(.deviceRGB) else { return false }
                    return abs(color.redComponent - resolved.redComponent) < 0.02 &&
                        abs(color.greenComponent - resolved.greenComponent) < 0.02 &&
                        abs(color.blueComponent - resolved.blueComponent) < 0.02
                }
                XCTAssertEqual(matchingPixels.count, 4, "Marker thickness must stay fixed while the navigation rail widens")
                if x == width - 8 {
                    XCTAssertEqual(matchingPixels.last, width - 7, "Deleted markers touch the adjacent added lane")
                } else if x == width - 4 {
                    XCTAssertEqual(matchingPixels.first, width - 6)
                }
            }
            var current: NSColor!
            appearance.performAsCurrentDrawingAppearance { current = Theme.currentSearchMatch.usingColorSpace(.deviceRGB) }
            let active = try XCTUnwrap(bitmap.colorAt(x: 3, y: 39)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(active.redComponent, current.redComponent, accuracy: 0.02)
            XCTAssertEqual(active.greenComponent, current.greenComponent, accuracy: 0.02)
            XCTAssertEqual(active.blueComponent, current.blueComponent, accuracy: 0.02)
        }
        }
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
