import AppKit
import XCTest
@testable import VCode

final class EditorTabsTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func titles(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child -> [NSButton] in
            if let button = child as? NSButton, !button.title.isEmpty { return [button] }
            return titles(in: child)
        }
    }

    func testContextMenusAreRelativeToClickedTabAndDisableEmptyGroups() throws {
        var session = ReaderSession()
        for path in ["a.ts", "b.ts", "c.ts"] { session.open(path) }
        let tabs = EditorTabs()
        tabs.show(session)
        let buttons = titles(in: tabs)
        XCTAssertEqual(buttons.map(\.title), ["a.ts", "b.ts", "c.ts"])
        let first = try XCTUnwrap(buttons[0].menu), middle = try XCTUnwrap(buttons[1].menu), last = try XCTUnwrap(buttons[2].menu)
        XCTAssertEqual(middle.items.map(\.title), ["Close All", "Close Others", "Close to the Right", "Close to the Left"])
        XCTAssertFalse(first.items[3].isEnabled)
        XCTAssertFalse(last.items[2].isEnabled)
        XCTAssertTrue(middle.items.allSatisfy(\.isEnabled))
        var closed: ReadingDocument?
        var scope: ReadingCloseScope?
        tabs.onCloseGroup = { closed = $0; scope = $1 }
        let item = middle.items[1]
        XCTAssertTrue(NSApp.sendAction(item.action!, to: item.target, from: item))
        XCTAssertEqual(closed, session.documents[1], "A non-active context tab must be the reference")
        XCTAssertEqual(scope, .others)
        XCTAssertEqual(session.activePath, "c.ts")
        session.close(.others, relativeTo: session.documents[1])
        tabs.show(session)
        let onlyMenu = try XCTUnwrap(titles(in: tabs).first?.menu)
        XCTAssertEqual(onlyMenu.items.map(\.isEnabled), [true, false, false, false])
        closed = nil
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        // A still-open reference remains valid; a reference removed by reset does not.
        tabs.show(ReaderSession())
        closed = nil
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        XCTAssertNil(closed)
    }

    func testEditorReorderKeepsReadingContentAndBulkCloseNotifiesOnlyOnce() throws {
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        editor.setWorkspaceOpen(true)
        for path in ["a.ts", "b.ts", "c.ts"] {
            editor.prepare(path: path, diff: false, isGit: false)
            editor.show(FileSnapshot(path: path, before: "", after: "export const current = '\(path)';", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        }
        let tabs = try XCTUnwrap(editor.subviews.compactMap { $0 as? EditorTabs }.first)
        var selections: [String] = [], lastClosed = 0
        editor.onSelectFile = { path, _ in selections.append(path) }
        editor.onLastTabClosed = { lastClosed += 1 }
        tabs.onMove?(ReadingDocument(path: "a.ts", comparison: nil), 3)
        XCTAssertEqual(titles(in: tabs).map(\.title), ["b.ts", "c.ts", "a.ts"])
        XCTAssertEqual(editor.activePath, "c.ts")
        XCTAssertTrue(editor.right.text.string.contains("c.ts"))
        XCTAssertTrue(selections.isEmpty, "Sorting must not read or select another document")
        let reference = try XCTUnwrap(titles(in: tabs).first?.menu)
        let closeRight = reference.items[2]
        _ = NSApp.sendAction(closeRight.action!, to: closeRight.target, from: closeRight)
        XCTAssertEqual(titles(in: tabs).map(\.title), ["b.ts"])
        XCTAssertEqual(editor.activePath, "b.ts")
        XCTAssertEqual(selections, ["b.ts"], "A bulk close must select its replacement only once")
        let closeAll = try XCTUnwrap(titles(in: tabs).first?.menu?.items.first)
        _ = NSApp.sendAction(closeAll.action!, to: closeAll.target, from: closeAll)
        XCTAssertNil(editor.activePath)
        XCTAssertEqual(lastClosed, 1)
        XCTAssertFalse(editor.welcome.isHidden)
        XCTAssertTrue(editor.right.text.string.isEmpty)
        editor.show(FileSnapshot(path: "b.ts", before: "", after: "late read", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        XCTAssertTrue(editor.right.text.string.isEmpty)
        XCTAssertFalse(editor.welcome.isHidden)
    }

    private func overflowingTabs(width: CGFloat = 500) throws -> (NSWindow, EditorTabs, ReaderSession, NSScrollView) {
        var session = ReaderSession()
        for index in 0..<16 { session.open("file-\(index).ts") }
        let tabs = EditorTabs()
        let height = 40 + NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tabs
        window.setContentSize(NSSize(width: width, height: height))
        tabs.show(session)
        tabs.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(tabs.subviews.compactMap { $0 as? NSScrollView }.first)
        XCTAssertGreaterThan(scroll.contentSize.width, 200)
        XCTAssertGreaterThan(scroll.documentView!.bounds.width, scroll.contentSize.width)
        return (window, tabs, session, scroll)
    }

    private func wheel(x: Int32 = 0, y: Int32 = 0, precise: Bool = false) throws -> NSEvent {
        // Construct an event for direct handler testing; never post it to the OS.
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    func testWheelOverTitleScrollsHorizontallyWithoutSelectingOrReordering() throws {
        let (window, tabs, session, scroll) = try overflowingTabs()
        defer { withExtendedLifetime(window) {} }
        let before = titles(in: tabs).map(\.title)
        let title = try XCTUnwrap(titles(in: tabs).first)
        var selected = 0
        tabs.onSelect = { _ in selected += 1 }
        scroll.contentView.scroll(to: .zero)
        title.scrollWheel(with: try wheel(y: -4))
        let afterVertical = scroll.contentView.bounds.minX
        XCTAssertGreaterThan(afterVertical, 0, "A regular mouse wheel over a tab must scroll the strip")
        title.scrollWheel(with: try wheel(x: -12, precise: true))
        XCTAssertEqual(scroll.contentView.bounds.minX, afterVertical + 12, accuracy: 0.5)
        title.scrollWheel(with: try wheel(x: 12, precise: true))
        XCTAssertEqual(scroll.contentView.bounds.minX, afterVertical, accuracy: 0.5)
        title.scrollWheel(with: try wheel(x: -100_000, precise: true))
        XCTAssertEqual(scroll.contentView.bounds.maxX, scroll.documentView!.bounds.maxX, accuracy: 0.5)
        title.scrollWheel(with: try wheel(y: 100_000, precise: true))
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 0.5)
        XCTAssertEqual(titles(in: tabs).map(\.title), before)
        XCTAssertEqual(session.activePath, "file-15.ts")
        XCTAssertEqual(selected, 0)
    }

    func testOverflowResizeAndBulkCloseKeepActiveTabVisibleWithoutSideButtons() throws {
        let (window, tabs, initial, scroll) = try overflowingTabs()
        defer { withExtendedLifetime(window) {} }
        var session = initial
        XCTAssertTrue(tabs.subviews.compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertEqual(scroll.frame.minX, 8, accuracy: 0.5)
        XCTAssertEqual(scroll.frame.maxX, tabs.bounds.width - 8, accuracy: 0.5)
        let active = try XCTUnwrap(titles(in: tabs).last?.superview)
        XCTAssertTrue(scroll.contentView.bounds.contains(active.frame))
        window.setContentSize(NSSize(width: 3000, height: 40))
        tabs.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
        window.setContentSize(NSSize(width: 400, height: 40 + NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)))
        tabs.layoutSubtreeIfNeeded()
        XCTAssertTrue(scroll.contentView.bounds.contains(active.frame), "Shrinking should reveal the active tab")
        session.close(.others, relativeTo: session.documents[0])
        tabs.show(session)
        tabs.layoutSubtreeIfNeeded()
        XCTAssertTrue(tabs.subviews.compactMap { $0 as? NSButton }.isEmpty)
        XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 0.5)
    }

    func testRebuildWithoutRevealPreservesBrowsedTabPosition() throws {
        let (window, tabs, session, scroll) = try overflowingTabs()
        defer { withExtendedLifetime(window) {} }
        scroll.contentView.scroll(to: NSPoint(x: 170, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        tabs.show(session, revealActive: false)
        tabs.layoutSubtreeIfNeeded()
        XCTAssertEqual(scroll.contentView.bounds.minX, 170, accuracy: 0.5)
        XCTAssertEqual(titles(in: tabs).map(\.title), (0..<16).map { "file-\($0).ts" })
    }

    func testNativeScrollbarRemainsDraggableAndDoesNotCoverTabs() throws {
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 650, height: 500))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        defer { withExtendedLifetime(window) {} }
        editor.setWorkspaceOpen(true)
        for index in 0..<12 { editor.prepare(path: "file-\(index).ts", diff: false, isGit: false) }
        editor.layoutSubtreeIfNeeded()
        let tabs = try XCTUnwrap(editor.subviews.compactMap { $0 as? EditorTabs }.first)
        let scroll = try XCTUnwrap(tabs.subviews.compactMap { $0 as? NSScrollView }.first)
        let knob = try XCTUnwrap(scroll.horizontalScroller)
        XCTAssertEqual(scroll.scrollerStyle, .legacy, "The drag entry must remain visible without first scrolling")
        XCTAssertEqual(knob.controlSize, .small)
        XCTAssertFalse(knob.isHidden)
        XCTAssertGreaterThanOrEqual(scroll.contentSize.height, 32)
        XCTAssertEqual(tabs.frame.height, 40 + NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy), accuracy: 0.5)
        let rect = knob.rect(for: .knob)
        XCTAssertGreaterThan(rect.width, 0)
        XCTAssertGreaterThan(rect.height, 0)
        XCTAssertTrue(scroll.hitTest(tabs.convert(NSPoint(x: rect.midX, y: rect.midY), from: knob)) === knob,
                      "The thumb must receive mouse input rather than a tab or close button")
        let active = editor.activePath
        let originalOrder = titles(in: tabs).map(\.title)
        // A native drag dispatches this same action with hitPart == .knob.
        // Supply the hit part without posting mouse input to the operating system.
        let dragged = DraggedThumbScroller(frame: knob.frame)
        dragged.controlSize = .small
        scroll.horizontalScroller = dragged
        scroll.reflectScrolledClipView(scroll.contentView)
        for fraction in [0.0, 0.5, 1.0] {
            dragged.doubleValue = fraction
            XCTAssertTrue(NSApp.sendAction(dragged.action!, to: dragged.target, from: dragged))
            let maximum = scroll.documentView!.bounds.width - scroll.contentSize.width
            XCTAssertEqual(scroll.contentView.bounds.minX, maximum * fraction, accuracy: 0.5,
                           "Native thumb actions must move the strip to the corresponding position")
            XCTAssertEqual(editor.activePath, active)
            XCTAssertEqual(titles(in: tabs).map(\.title), originalOrder)
        }
        window.setContentSize(NSSize(width: 3000, height: 500))
        editor.layoutSubtreeIfNeeded()
        XCTAssertTrue(dragged.isHidden)
        XCTAssertEqual(tabs.frame.height, 40, accuracy: 0.5)
        window.setContentSize(NSSize(width: 650, height: 500))
        editor.layoutSubtreeIfNeeded()
        XCTAssertFalse(dragged.isHidden)
        XCTAssertGreaterThanOrEqual(scroll.contentSize.height, 32)
        XCTAssertTrue(scroll.contentView.bounds.contains(try XCTUnwrap(titles(in: tabs).last?.superview).frame))
        let closeOthers = try XCTUnwrap(titles(in: tabs).last?.menu?.items[1])
        _ = NSApp.sendAction(closeOthers.action!, to: closeOthers.target, from: closeOthers)
        editor.layoutSubtreeIfNeeded()
        XCTAssertTrue(dragged.isHidden)
        XCTAssertEqual(tabs.frame.height, 40, accuracy: 0.5, "No track space should remain when every tab fits")
    }

    func testScrollingUnderStationaryPointerTransfersHoverWithoutLeavingOldHighlights() throws {
        var session = ReaderSession()
        for index in 0..<12 { session.open("file-\(index).ts") }
        let tabs = EditorTabs()
        let window = TabHoverWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 53), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tabs
        defer { withExtendedLifetime(window) {} }
        tabs.show(session)
        tabs.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(tabs.subviews.compactMap { $0 as? NSScrollView }.first)
        let contents = try titles(in: tabs).map { try XCTUnwrap($0.superview) }
        let closes = try contents.map { content in
            try XCTUnwrap(content.subviews.compactMap { $0 as? FeedbackButton }.first)
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        window.pointer = closes[0].convert(NSPoint(x: 12, y: 12), to: nil)
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: window.pointer, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        contents[0].mouseEntered(with: entered)
        closes[0].mouseEntered(with: entered)
        XCTAssertGreaterThan(contents[0].layer!.backgroundColor!.alpha, 0)
        XCTAssertGreaterThan(closes[0].layer!.backgroundColor!.alpha, 0)
        var selected = 0, closed = 0
        tabs.onSelect = { _ in selected += 1 }; tabs.onClose = { _ in closed += 1 }
        // Scroll the document underneath a pointer which never moves. AppKit
        // need not deliver an exit for a tracking area removed by scrolling.
        for index in [1, 2, 0] {
            scroll.contentView.scroll(to: NSPoint(x: contents[index].frame.minX - contents[0].frame.minX, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
            if index != 0 {
                // A delayed enter from an obsolete area must not revive it.
                contents[0].mouseEntered(with: entered)
                closes[0].mouseEntered(with: entered)
            }
            for candidate in 0..<3 {
                XCTAssertEqual(contents[candidate].layer!.backgroundColor!.alpha > 0, candidate == index)
                XCTAssertEqual(closes[candidate].layer!.backgroundColor!.alpha > 0, candidate == index)
            }
        }
        // Rebuilding a tracking area must not retain its previous boolean state.
        window.pointer = NSPoint(x: -100, y: -100)
        contents[0].updateTrackingAreas(); closes[0].updateTrackingAreas()
        XCTAssertEqual(contents[0].layer!.backgroundColor!.alpha, 0)
        XCTAssertEqual(closes[0].layer!.backgroundColor!.alpha, 0)
        XCTAssertEqual(selected, 0); XCTAssertEqual(closed, 0)
        XCTAssertEqual(titles(in: tabs).map(\.title), (0..<12).map { "file-\($0).ts" })
    }

    func testMouseReleaseSelectsOnceIncludingTabPadding() throws {
        var session = ReaderSession()
        session.open("a.ts"); session.open("b.ts")
        let tabs = EditorTabs()
        let window = TabEventWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tabs
        defer { withExtendedLifetime(window) {} }
        tabs.show(session)
        tabs.layoutSubtreeIfNeeded()
        let title = try XCTUnwrap(titles(in: tabs).first)
        let content = try XCTUnwrap(title.superview)
        XCTAssertTrue(title.window === window)
        XCTAssertGreaterThan(content.bounds.width, 100)
        XCTAssertGreaterThan(content.bounds.height, 20)
        var selected: [ReadingDocument] = []
        tabs.onSelect = { selected.append($0) }
        for (view, point) in [(title as NSView, NSPoint(x: title.bounds.midX, y: title.bounds.midY)), (content, NSPoint(x: 2, y: content.bounds.midY))] {
            let location = view.convert(point, to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            window.events = [up]
            view.mouseDown(with: down)
        }
        XCTAssertEqual(selected, [session.documents[0], session.documents[0]])
    }
}

private final class DraggedThumbScroller: NSScroller {
    override var hitPart: NSScroller.Part { .knob }
}

private final class TabHoverWindow: NSWindow {
    var pointer = NSPoint(x: -100, y: -100)
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { true }
}

private final class TabEventWindow: NSWindow {
    var events: [NSEvent] = []
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue deqFlag: Bool) -> NSEvent? {
        // AppKit rewrites posted mouse coordinates for an offscreen test window.
        // Supply window-relative events here; the actual event queue is verified in the app.
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }
}
