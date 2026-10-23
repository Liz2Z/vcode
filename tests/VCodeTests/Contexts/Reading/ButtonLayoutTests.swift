import AppKit
import XCTest
@testable import VCode

final class ButtonLayoutTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testSidebarTitlesFitAfterRepeatedNarrowAndWideLayouts() throws {
        let navigation = WorkspaceNavigation()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = navigation
        defer { withExtendedLifetime(window) {} }
        for width: CGFloat in [360, 208, 280, 208, 360, 240, 208] {
            window.setContentSize(NSSize(width: width, height: 40))
            navigation.select(changes: width == 208)
            navigation.layoutSubtreeIfNeeded()
            for button in [navigation.files, navigation.changes, navigation.search] {
                let stack = try XCTUnwrap(button.subviews.compactMap { $0 as? NSStackView }.first)
                let label = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
                let image = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
                XCTAssertGreaterThanOrEqual(label.frame.width, label.intrinsicContentSize.width - 0.5, "Fixed navigation titles must not truncate at width \(width)")
                XCTAssertTrue(image.isHidden)
                XCTAssertGreaterThanOrEqual(stack.frame.minX, 7.5)
                XCTAssertLessThanOrEqual(stack.frame.maxX, button.bounds.width - 7.5)
            }
        }
    }

    func testIconAndTitleStayCenteredWhenTruncatedOrStateChanges() throws {
        let button = Theme.actionButton("—", symbol: "folder")
        button.horizontalPadding = 12
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSView()
        window.contentView = host
        host.add(button)
        let width = button.widthAnchor.constraint(equalToConstant: 200)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: host.centerXAnchor), button.centerYAnchor.constraint(equalTo: host.centerYAnchor), button.heightAnchor.constraint(equalToConstant: 32), width])
        let stack = try XCTUnwrap(button.subviews.compactMap { $0 as? NSStackView }.first)
        let image = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
        let label = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        for title in ["idev-002", "a-very-long-worktree-name-that-must-be-truncated"] {
            button.title = title
            for availableWidth: CGFloat in [200, 120] {
                width.constant = availableWidth
                for state in 0..<4 {
                    button.isSelected = state == 1
                    button.isEnabled = state != 3
                    let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, subtype: 0, data1: 0, data2: 0)!
                    if state == 2 { button.mouseEntered(with: event) } else { button.mouseExited(with: event) }
                    host.layoutSubtreeIfNeeded()
                    let iconRect = image.convert(image.bounds, to: button)
                    let titleRect = label.convert(label.bounds, to: button)
                    XCTAssertEqual(iconRect.midY, button.bounds.midY, accuracy: 0.5)
                    XCTAssertEqual(titleRect.midY, iconRect.midY, accuracy: 0.5)
                    XCTAssertGreaterThanOrEqual(titleRect.minX - iconRect.maxX, 5.5)
                    XCTAssertGreaterThanOrEqual(iconRect.minX, 11.5)
                    XCTAssertLessThanOrEqual(titleRect.maxX, button.bounds.maxX - 11.5)
                    XCTAssertTrue(button.hitTest(NSPoint(x: button.frame.minX + iconRect.midX, y: button.frame.minY + iconRect.midY)) === button)
                    XCTAssertTrue(button.hitTest(NSPoint(x: button.frame.minX + titleRect.midX, y: button.frame.minY + titleRect.midY)) === button)
                }
            }
        }
    }

    func testIconOnlyCloseButtonStaysSquareAndCentered() throws {
        let button = Theme.button("xmark", tooltip: "Close", target: nil, action: nil)
        button.frame = NSRect(x: 0, y: 0, width: 24, height: 24)
        button.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(button.subviews.compactMap { $0 as? NSStackView }.first)
        let image = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
        let rect = image.convert(image.bounds, to: button)
        XCTAssertEqual(rect.midX, 12, accuracy: 0.5)
        XCTAssertEqual(rect.midY, 12, accuracy: 0.5)
        XCTAssertEqual(button.frame.width, button.frame.height)
    }
}
