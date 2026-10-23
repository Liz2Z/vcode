import AppKit
import XCTest
@testable import VCode

final class WorkspaceSplitViewTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testLeftRecentRailResizesAcrossThresholdWithoutSqueezingEditorGroups() throws {
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = workspace
        defer { window.close() }
        let root = URL(fileURLWithPath: "/tmp/recent-spacing")
        let entry = RecentWorkspace(state: WorkspaceState(root: root, files: [], git: nil), openedAt: Date())
        let recent = WorkspaceHistorySidebar(entries: [entry], current: root, available: { _ in true })
        workspace.recentHost.add(recent.view)
        Theme.pin(recent.view, to: workspace.recentHost)
        for width: Double in [48, 159, 160, 240, 360, 48] {
            workspace.restoreRecentSidebarWidth(width)
            workspace.layoutSubtreeIfNeeded()
            XCTAssertEqual(workspace.recentSidebarWidth, width, accuracy: 0.5)
            XCTAssertEqual(workspace.recentHost.frame.minX, 0, accuracy: 0.5)
            XCTAssertEqual(workspace.contentSplit.frame.maxX, workspace.recentSplit.bounds.maxX, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(workspace.editorGroups.bounds.width, 220)
            XCTAssertEqual(workspace.recentSplit.dividerThickness, 12)
            recent.view.layoutSubtreeIfNeeded()
            let visibleRecent: NSRect
            if recent.isCompact {
                let row = try XCTUnwrap(recent.table.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
                visibleRecent = row.convert(row.backgroundRect, to: workspace)
            } else {
                visibleRecent = recent.view.convert(recent.view.bounds, to: workspace)
            }
            let files = workspace.contentSplit.arrangedSubviews[0]
            let filesRect = files.convert(files.bounds, to: workspace)
            let editorRect = workspace.editorGroups.convert(workspace.editorGroups.bounds, to: workspace)
            XCTAssertEqual(visibleRecent.minX, Theme.Layout.inset, accuracy: 0.5, "Visible left margin must match the right margin, including row background insets")
            XCTAssertEqual(workspace.bounds.maxX - editorRect.maxX, Theme.Layout.inset, accuracy: 0.5)
            XCTAssertEqual(filesRect.minX - visibleRecent.maxX, Theme.Layout.moduleGap, accuracy: 0.5, "Recent-to-Files visible gap must match Files-to-editor")
            XCTAssertEqual(editorRect.minX - filesRect.maxX, Theme.Layout.moduleGap, accuracy: 0.5)
        }
        workspace.restoreRecentSidebarWidth(360)
        workspace.editorGroups.setWorkspaceOpen(true)
        workspace.editorGroups.splitActiveEditor(copyDocument: false)
        for width: CGFloat in [920, 1360, 920] {
            window.setContentSize(NSSize(width: width, height: 700))
            workspace.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(workspace.recentSidebarWidth, 48)
            XCTAssertLessThanOrEqual(workspace.recentSidebarWidth, 360)
            XCTAssertGreaterThanOrEqual(workspace.sidebarWidth, 220)
            XCTAssertGreaterThanOrEqual(workspace.editorGroups.bounds.width, workspace.editorGroups.minimumWidth - 0.5)
        }
    }

    func testSidebarTravelUsesAvailableWidthAndKeepsBothPanesAtLeast220() throws {
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        defer { withExtendedLifetime(window) {} }
        let split = try XCTUnwrap(Optional(workspace.contentSplit))
        for width: CGFloat in [1360, 920, 1700, 920] {
            window.setContentSize(NSSize(width: width, height: 700))
            workspace.layoutSubtreeIfNeeded()
            split.setPosition(10_000, ofDividerAt: 0)
            workspace.layoutSubtreeIfNeeded()
            let panes = split.arrangedSubviews
            XCTAssertEqual(panes[0].frame.width, split.bounds.width - split.dividerThickness - 220, accuracy: 0.5)
            XCTAssertEqual(panes[1].frame.width, 220, accuracy: 0.5)
            XCTAssertGreaterThan(panes[0].frame.width, 360, "The former fixed maximum must not constrain travel")
            split.setPosition(-100, ofDividerAt: 0)
            XCTAssertEqual(panes[0].frame.width, 220, accuracy: 0.5)
            XCTAssertEqual(panes[1].frame.maxX, split.bounds.maxX, accuracy: 0.5)
            XCTAssertEqual(split.dividerThickness, 12, "Extending travel must not widen the gap")
        }
        split.setPosition(700, ofDividerAt: 0)
        window.setContentSize(NSSize(width: 920, height: 700))
        workspace.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(split.arrangedSubviews[1].frame.width, 220)
    }

    func testResizeHintClearsOnExitAndTrackingFollowsDivider() throws {
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        defer { withExtendedLifetime(window) {} }
        workspace.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(Optional(workspace.contentSplit))
        for position: CGFloat in [220, 700, 1000, 240] {
            split.setPosition(position, ofDividerAt: 0)
            let areas = split.trackingAreas.filter { ($0.owner as? WorkspaceSplitView) === split }
            let area = try XCTUnwrap(areas.first)
            XCTAssertEqual(areas.count, 1)
            XCTAssertEqual(area.rect.minX, split.arrangedSubviews[0].frame.maxX, accuracy: 0.5)
            XCTAssertEqual(area.rect.width, split.dividerThickness, accuracy: 0.5)
            let point = split.convert(NSPoint(x: area.rect.midX, y: area.rect.midY), to: nil)
            let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
            let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 0, userData: nil))
            split.mouseEntered(with: entered)
            XCTAssertTrue(split.isResizeHovered)
            split.mouseExited(with: exited)
            XCTAssertFalse(split.isResizeHovered)
            XCTAssertFalse(split.isResizing)
        }
    }

    func testResizeCursorStaysBidirectionalAtBothLimitsAndAfterMoving() throws {
        let originalCursor = NSCursor.current
        defer { originalCursor.set() }
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        defer { withExtendedLifetime(window) {} }
        workspace.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(Optional(workspace.contentSplit))
        for position: CGFloat in [-100, 10_000, 700, -100] {
            split.setPosition(position, ofDividerAt: 0)
            let area = try XCTUnwrap(split.trackingAreas.first { ($0.owner as? WorkspaceSplitView) === split })
            XCTAssertTrue(area.options.contains(.cursorUpdate))
            XCTAssertTrue(area.options.contains(.enabledDuringMouseDrag))
            let point = split.convert(NSPoint(x: area.rect.midX, y: area.rect.midY), to: nil)
            let update = try XCTUnwrap(NSEvent.enterExitEvent(with: .cursorUpdate, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
            NSCursor.resizeRight.set()
            split.cursorUpdate(with: update)
            XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
            let moved = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 0, pressure: 0))
            NSCursor.resizeLeft.set()
            split.mouseMoved(with: moved)
            XCTAssertEqual(NSCursor.current, NSCursor.resizeLeftRight)
        }
    }
}
