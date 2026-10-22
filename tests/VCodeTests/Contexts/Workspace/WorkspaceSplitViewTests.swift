import AppKit
import XCTest
@testable import VCode

final class WorkspaceSplitViewTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testSidebarTravelUsesAvailableWidthAndKeepsBothPanesAtLeast220() throws {
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = workspace
        defer { withExtendedLifetime(window) {} }
        let split = try XCTUnwrap(workspace.subviews.compactMap { $0 as? WorkspaceSplitView }.first)
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
        let split = try XCTUnwrap(workspace.subviews.compactMap { $0 as? WorkspaceSplitView }.first)
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
        let split = try XCTUnwrap(workspace.subviews.compactMap { $0 as? WorkspaceSplitView }.first)
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
