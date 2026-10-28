import AppKit
import XCTest
@testable import VCode

final class EditorFindTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func fixture(_ source: String, diff: Bool = false, path: String = "main.ts") -> (EditorView, NSWindow) {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        editor.prepare(path: path, diff: diff, isGit: true)
        let rows = Diff.lines(source).enumerated().map { index, text in
            DiffRow(left: CodeLine(number: index + 1, text: text, kind: .unchanged), right: CodeLine(number: index + 1, text: text, kind: .unchanged))
        }
        editor.show(FileSnapshot(path: path, before: source, after: source, rows: rows, message: nil, isBinary: false), diff: diff, preserveScroll: false)
        window.makeKeyAndOrderFront(nil)
        editor.layoutSubtreeIfNeeded()
        return (editor, window)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) {
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 5)
    }

    func testFindSeedsSelectionHighlightsUnicodeAndWrapsWithoutEditingSource() throws {
        let source = "// 中文😀\nconst target = 1;\ntarget + target;\n"
        let (editor, window) = fixture(source)
        defer { editor.find.close(); window.close() }
        let text = editor.right.text
        let first = (text.string as NSString).range(of: "target")
        text.setSelectedRange(first)
        editor.performFind(.showFindInterface)
        waitUntil { text.searchRanges.count == 3 }
        XCTAssertTrue(editor.findBar.isFindBarVisible)
        XCTAssertEqual(editor.right.diffOverview.searchRows, [1, 2])
        XCTAssertTrue(editor.right.diffOverview.occurrenceRows.isEmpty)
        XCTAssertEqual(editor.right.diffOverview.currentSearchRows, [1])
        XCTAssertEqual((text.layoutManager as? CodeLayoutManager)?.searchRanges, text.searchRanges)
        let matches = text.searchRanges
        guard matches.count == 3 else { return }
        text.setSelectedRange(first)
        editor.performFind(.nextMatch)
        XCTAssertEqual(text.selectedRange(), matches[1])
        editor.performFind(.previousMatch)
        XCTAssertEqual(text.selectedRange(), first)
        editor.performFind(.previousMatch)
        XCTAssertEqual(text.selectedRange(), matches[2])
        text.setSelectedRange(NSRange(location: matches[1].location, length: 0))
        editor.performFind(.nextMatch)
        XCTAssertEqual(text.selectedRange(), matches[1], "Navigation follows a manually moved caret")
        XCTAssertEqual(text.string, source)
        XCTAssertFalse(text.isEditable)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        text.keyDown(with: escape)
        XCTAssertFalse(editor.findBar.isFindBarVisible)
        XCTAssertTrue(text.searchRanges.isEmpty)
        XCTAssertTrue(editor.right.diffOverview.occurrenceRows.isEmpty)
    }

    func testDiffFindUsesFocusedVersionAndFloatingBarWithoutMovingBodyOrErasingSymbolMarks() {
        let (editor, window) = fixture("const target = 1;\ntarget;\n", diff: true)
        defer { editor.find.close(); window.close() }
        let range = (editor.left.text.string as NSString).range(of: "target")
        window.makeFirstResponder(editor.left.text)
        editor.left.text.setSelectedRange(range)
        let body = editor.right.superview?.frame
        let viewport = editor.right.scroll.frame
        editor.performFind(.showFindInterface)
        waitUntil { editor.left.text.searchRanges.count == 2 }
        editor.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.find.currentPane === editor.left)
        XCTAssertEqual(editor.findBar.frame.width, 420, accuracy: 1)
        XCTAssertEqual(editor.findBar.frame.maxX, editor.bounds.maxX - DiffOverview.preferredWidth - 8, accuracy: 1)
        XCTAssertGreaterThan(editor.findBar.frame.height, 20)
        let code = editor.convert(editor.right.scroll.bounds, from: editor.right.scroll)
        XCTAssertLessThanOrEqual(editor.findBar.frame.maxY, code.maxY - 8, "The floating query starts below Original/Modified headers")
        XCTAssertEqual(editor.right.superview?.frame, body)
        XCTAssertEqual(editor.right.scroll.frame, viewport)
        XCTAssertEqual(editor.right.diffOverview.searchRows, [0, 1])
        XCTAssertEqual(editor.right.diffOverview.currentSearchRows, [0])
        XCTAssertTrue(editor.right.text.searchRanges.isEmpty)
        let rightRange = (editor.right.text.string as NSString).range(of: "target")
        editor.right.text.onSymbolClick = { _, reply in reply([rightRange]) }
        editor.right.text.highlightSymbol(at: rightRange.location)
        editor.find.close()
        XCTAssertEqual(editor.right.diffOverview.occurrenceRows, [0], "Closing Find must not erase independent semantic highlights")
        XCTAssertTrue(editor.left.text.searchRanges.isEmpty)
        XCTAssertTrue(editor.right.diffOverview.searchRows.isEmpty)
        XCTAssertTrue(editor.right.diffOverview.currentSearchRows.isEmpty)
    }

    func testCurrentMatchMovesIndependentlyAndManualSelectionRestoresSystemAppearance() throws {
        let (editor, window) = fixture("target;\ntarget;\ntarget;\n")
        defer { editor.find.close(); window.close() }
        let pane = editor.right
        pane.text.setSelectedRange(NSRange(location: 0, length: 6))
        editor.performFind(.showFindInterface)
        waitUntil { pane.text.searchRanges.count == 3 }
        let matches = pane.text.searchRanges
        guard matches.count == 3 else { return }
        XCTAssertEqual(pane.text.currentSearchRange, matches[0])
        XCTAssertTrue(pane.text.isFindSelection)
        XCTAssertEqual((pane.text.selectedTextAttributes[.backgroundColor] as? NSColor)?.alphaComponent, 0)
        editor.performFind(.nextMatch)
        XCTAssertEqual(pane.text.currentSearchRange, matches[1])
        XCTAssertEqual(pane.diffOverview.currentSearchRows, [1])
        XCTAssertEqual(pane.diffOverview.searchRows, [0, 1, 2])
        pane.text.setSelectedRange(matches[1])
        XCTAssertFalse(pane.text.isFindSelection, "A real selection, even over the current match, uses the system appearance")
        XCTAssertEqual(pane.text.selectedTextAttributes[.backgroundColor] as? NSColor, NSColor.selectedTextBackgroundColor)
        editor.find.close()
        XCTAssertNil(pane.text.currentSearchRange)
        XCTAssertTrue(pane.diffOverview.searchRows.isEmpty)
        XCTAssertTrue(pane.diffOverview.currentSearchRows.isEmpty)
    }

    func testPartialOverlapsKeepOnlyUncoveredSemanticCharacters() {
        XCTAssertEqual(CodeLayoutManager.uncovered(NSRange(location: 3, length: 10), excluding: [NSRange(location: 5, length: 3), NSRange(location: 7, length: 3)]),
                       [NSRange(location: 3, length: 2), NSRange(location: 10, length: 3)])
        XCTAssertTrue(CodeLayoutManager.uncovered(NSRange(location: 3, length: 10), excluding: [NSRange(location: 0, length: 30)]).isEmpty)
    }

    func testSearchDoesNotBlendWithSymbolBackgroundAndCurrentMatchHasDistinctOutlineInBothThemes() throws {
        let (editor, window) = fixture("const target = 1;\ntarget;\n")
        defer { editor.find.close(); window.close() }
        let pane = editor.right
        let range = (pane.text.string as NSString).range(of: "target")
        let layout = try XCTUnwrap(pane.text.layoutManager as? CodeLayoutManager)
        let container = try XCTUnwrap(pane.text.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let area = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: pane.text.textContainerOrigin.x, dy: pane.text.textContainerOrigin.y).insetBy(dx: -5, dy: -3)
        func render(search: Bool, symbol: Bool, current: Bool, selection: Bool = false) throws -> Data {
            pane.text.setSelectedRange(selection ? range : NSRange(location: 0, length: 0))
            layout.searchRanges = search ? [range] : []
            layout.symbolRanges = symbol ? [range] : []
            layout.currentSearchRange = current ? range : nil
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            Theme.background.setFill()
            NSRect(x: 0, y: 0, width: 300, height: 100).fill()
            layout.drawBackground(forGlyphRange: layout.glyphRange(for: container), at: pane.text.textContainerOrigin)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            XCTAssertGreaterThan(area.width, 10)
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            var data = Data()
            for row in 0..<bitmap.pixelsHigh { data.append(pixels.advanced(by: row * bitmap.bytesPerRow), count: bitmap.pixelsWide * 4) }
            return data
        }
        for theme in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: theme))
            var error: Error?
            appearance.performAsCurrentDrawingAppearance {
                do {
                    let plain = try render(search: false, symbol: false, current: false)
                    let symbol = try render(search: false, symbol: true, current: false)
                    let search = try render(search: true, symbol: false, current: false)
                    let current = try render(search: true, symbol: false, current: true)
                    XCTAssertNotEqual(plain, symbol)
                    XCTAssertNotEqual(search, symbol)
                    XCTAssertNotEqual(search, current, "Current match has a stronger cyan fill and a fine outline")
                    XCTAssertEqual(search, try render(search: true, symbol: true, current: false), "Symbol yellow must not blend underneath cyan")
                    XCTAssertEqual(current, try render(search: true, symbol: true, current: true))
                    XCTAssertEqual(try render(search: false, symbol: false, current: false, selection: true),
                                   try render(search: true, symbol: true, current: true, selection: true), "Native selection wins over search and symbol fills")
                } catch let caught { error = caught }
            }
            if let error { throw error }
        }
    }

    func testReplacingDocumentCancelsSearchAndRejectsStaleMatches() {
        let (editor, window) = fixture(String(repeating: "target;\n", count: 1000))
        defer { editor.find.close(); window.close() }
        editor.right.text.setSelectedRange(NSRange(location: 0, length: 6))
        editor.performFind(.showFindInterface)
        waitUntil { !editor.right.text.searchRanges.isEmpty }
        editor.prepare(path: "other.ts", diff: false, isGit: true)
        editor.show(FileSnapshot(path: "other.ts", before: "", after: "const other = 1;", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(editor.findBar.isFindBarVisible)
        XCTAssertTrue(editor.right.text.searchRanges.isEmpty)
        XCTAssertTrue(editor.right.diffOverview.occurrenceRows.isEmpty)
        editor.reset()
        XCTAssertFalse(editor.findBar.isFindBarVisible)
    }

    func testLiteralCaseWholeWordAndUnicodeOffsets() {
        let source = "😀 foo Foo food _foo foo$ 中文foo foo中文 foo\n[a.*] [a.*]"
        let insensitive = EditorFind.find("foo", in: source, matchCase: false, wholeWord: false)
        XCTAssertEqual(insensitive.count, 8)
        XCTAssertEqual(insensitive.first?.location, 3, "Offsets must use UTF-16 after emoji")
        XCTAssertEqual(EditorFind.find("foo", in: source, matchCase: true, wholeWord: true).count, 2)
        XCTAssertEqual(EditorFind.find("foo", in: source, matchCase: false, wholeWord: true).count, 3)
        XCTAssertEqual(EditorFind.find("[a.*]", in: source, matchCase: false, wholeWord: false).count, 2, "Queries are literal, not regular expressions")
        XCTAssertTrue(EditorFind.find("", in: source, matchCase: false, wholeWord: false).isEmpty)
        XCTAssertTrue(EditorFind.find("missing", in: source, matchCase: false, wholeWord: false).isEmpty)
        XCTAssertTrue(EditorFind.find("foo", in: source, matchCase: false, wholeWord: false, cancelled: { true }).isEmpty)
    }

    func testOptionsEmptyQueryAndNarrowFloatingBounds() {
        let (editor, window) = fixture("target TARGET targetExtra")
        defer { editor.find.close(); window.close() }
        editor.right.text.setSelectedRange(NSRange(location: 0, length: 6))
        editor.performFind(.showFindInterface)
        waitUntil { editor.find.matches.count == 3 }
        editor.findBar.matchCase.performClick(nil)
        waitUntil { editor.find.matches.count == 2 }
        XCTAssertTrue(editor.findBar.matchCase.isSelected)
        editor.findBar.wholeWord.performClick(nil)
        waitUntil { editor.find.matches.count == 1 }
        XCTAssertEqual(editor.findBar.count.stringValue, "1 / 1")
        window.setContentSize(NSSize(width: 220, height: 600))
        editor.layoutSubtreeIfNeeded()
        let rail = editor.convert(editor.right.diffOverview.bounds, from: editor.right.diffOverview)
        XCTAssertLessThanOrEqual(editor.findBar.frame.maxX, rail.minX - 8)
        XCTAssertGreaterThanOrEqual(editor.findBar.frame.minX, editor.bounds.minX + 8)
        XCTAssertFalse(editor.findBar.frame.intersects(rail))
        XCTAssertGreaterThan(editor.findBar.query.frame.width, 20)
        if #available(macOS 26.0, *) {
            let surface = editor.findBar.subviews.compactMap { $0 as? GlassSurface }.first
            XCTAssertTrue(surface?.material is NSGlassEffectView)
        }
        editor.findBar.query.stringValue = "missing"
        editor.findBar.onQuery?()
        waitUntil { editor.findBar.count.stringValue == "No results" }
        XCTAssertFalse(editor.findBar.next.isEnabled)
        editor.findBar.query.stringValue = ""
        editor.findBar.onQuery?()
        XCTAssertEqual(editor.findBar.count.stringValue, "")
        XCTAssertTrue(editor.right.text.searchRanges.isEmpty)
    }

    func testDraftEditingRefreshesMatchesWithoutSelectingOrMovingInputCaret() throws {
        let (editor, window) = fixture("source")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-find-" + UUID().uuidString)
        editor.draftStore = TextDraftStore(directory: root)
        defer { editor.find.close(); editor.reset(); window.close(); try? FileManager.default.removeItem(at: root) }
        editor.setWorkspaceOpen(true)
        editor.newTextTab()
        editor.right.text.insertText("target target", replacementRange: NSRange(location: 0, length: 0))
        editor.right.text.setSelectedRange(NSRange(location: 0, length: 6))
        editor.performFind(.showFindInterface)
        waitUntil { editor.find.matches.count == 2 }
        window.makeFirstResponder(editor.right.text)
        editor.right.text.insertText("x", replacementRange: NSRange(location: 0, length: 1))
        let caret = editor.right.text.selectedRange()
        waitUntil { editor.find.matches.count == 1 }
        XCTAssertEqual(editor.right.text.selectedRange(), caret)
        XCTAssertEqual(editor.right.text.string, "xarget target")
        XCTAssertTrue(editor.right.text.isEditable)
        XCTAssertTrue(editor.findBar.isFindBarVisible)
    }

    func testMarkdownFindEntersSourceAndGroupsKeepIndependentQueries() {
        let (markdown, firstWindow) = fixture("# target\n中文😀 target", path: "README.md")
        defer { markdown.find.close(); firstWindow.close() }
        waitUntil { !markdown.markdown.isRendering }
        XCTAssertTrue(markdown.showingMarkdownPreview)
        markdown.right.text.setSelectedRange((markdown.right.text.string as NSString).range(of: "target"))
        markdown.performFind(.showFindInterface)
        waitUntil { markdown.find.matches.count == 2 }
        XCTAssertFalse(markdown.showingMarkdownPreview)
        XCTAssertFalse(markdown.right.text.isEditable)
        let (other, secondWindow) = fixture("other other other")
        defer { other.find.close(); secondWindow.close() }
        other.right.text.setSelectedRange(NSRange(location: 0, length: 5))
        other.performFind(.showFindInterface)
        waitUntil { other.find.matches.count == 3 }
        XCTAssertEqual(markdown.findBar.query.stringValue, "target")
        XCTAssertEqual(markdown.right.text.searchRanges.count, 2)
        other.find.close()
        XCTAssertTrue(markdown.findBar.isFindBarVisible)
        XCTAssertEqual(markdown.find.matches.count, 2)
        markdown.showError(GitError.command("Unavailable"))
        XCTAssertFalse(markdown.canFind)
        markdown.performFind(.showFindInterface)
        XCTAssertFalse(markdown.findBar.isFindBarVisible)
    }

    func testFirstHoverUsesHandForButtonsAndTextCursorForInputWithoutUnderlyingCodeOverride() throws {
        let original = NSCursor.current
        defer { original.set() }
        let (editor, window) = fixture("target target")
        defer { editor.find.close(); window.close() }
        editor.right.text.setSelectedRange(NSRange(location: 0, length: 6))
        editor.performFind(.showFindInterface)
        waitUntil { editor.find.matches.count == 2 }
        editor.layoutSubtreeIfNeeded()
        let bar = editor.findBar
        bar.updateTrackingAreas()
        let areas = bar.trackingAreas.filter { ($0.owner as? EditorFindBar) === bar }
        XCTAssertTrue(areas.contains { $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .activeAlways]) })
        XCTAssertTrue(areas.contains { $0.options.contains([.cursorUpdate, .activeInKeyWindow]) })
        func move(_ view: NSView, at point: NSPoint? = nil, expected: NSCursor) throws {
            let location = view.convert(point ?? NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for type in [NSEvent.EventType.mouseEntered, .cursorUpdate, .mouseMoved] {
                let event: NSEvent
                if type == .mouseMoved {
                    event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
                } else {
                    event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
                }
                NSCursor.crosshair.set()
                switch type {
                case .mouseEntered: bar.mouseEntered(with: event)
                case .cursorUpdate: bar.cursorUpdate(with: event)
                default: bar.mouseMoved(with: event)
                }
                XCTAssertEqual(NSCursor.current, expected, "\(type) at \(String(describing: view)) \(location), actual: hand=\(NSCursor.current == .pointingHand) text=\(NSCursor.current == .iBeam) arrow=\(NSCursor.current == .arrow)")
                if type == .mouseMoved {
                    editor.right.text.mouseMoved(with: event)
                    XCTAssertEqual(NSCursor.current, expected, "Obscured text must not overwrite the floating control cursor")
                }
            }
        }
        for button in [bar.matchCase, bar.wholeWord, bar.previous, bar.next, bar.closeButton] {
            try move(button, expected: .pointingHand)
        }
        try move(bar.query, expected: .iBeam)
        let cancel = bar.query.cancelButtonBounds
        try move(bar.query, at: NSPoint(x: cancel.midX, y: cancel.midY), expected: .pointingHand)
        try move(bar.count, expected: .arrow)
        bar.query.stringValue = "missing"; bar.onQuery?()
        waitUntil { bar.count.stringValue == "No results" }
        try move(bar.next, expected: .arrow)
        try move(bar.matchCase, expected: .pointingHand)
    }
}
