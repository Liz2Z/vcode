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

private final class TabEventWindow: NSWindow {
    var events: [NSEvent] = []
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue deqFlag: Bool) -> NSEvent? {
        // AppKit rewrites posted mouse coordinates for an offscreen test window.
        // Supply window-relative events here; the actual event queue is verified in the app.
        guard !events.isEmpty else { return nil }
        return events.removeFirst()
    }
}
