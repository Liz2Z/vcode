import AppKit
import XCTest
@testable import VCode

final class InspectionPresentationTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testHoverRendersHighlightedCodeAndFormattedDocumentation() throws {
        let rendered = HoverTextRenderer.render("""
        ```typescript
        (property) settings: {
            port: number;
            label: string;
        }
        ```

        **Server settings** with `port`.

        - First item
        - Second item
        """)
        XCTAssertFalse(rendered.string.contains("```"))
        XCTAssertFalse(rendered.string.contains("**"))
        XCTAssertTrue(rendered.string.contains("    port: number;\n"))
        XCTAssertTrue(rendered.string.contains("• First item"))
        let source = rendered.string as NSString
        let port = source.range(of: "port:").location
        let primitive = source.range(of: "number").location
        XCTAssertNotEqual(rendered.attribute(.foregroundColor, at: port, effectiveRange: nil) as? NSColor, rendered.attribute(.foregroundColor, at: primitive, effectiveRange: nil) as? NSColor)
        let font = try XCTUnwrap(rendered.attribute(.font, at: port, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 12)
        XCTAssertEqual(font.familyName, NSFont(name: "Monaco", size: 12) != nil ? "Monaco" : "Menlo")
        let prose = source.range(of: "Server settings").location
        let proseFont = try XCTUnwrap(rendered.attribute(.font, at: prose, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: proseFont).contains(.boldFontMask))
    }

    func testHoverRemainsInsideWindowAtEveryCornerAndFlipsAboveBottomEdge() {
        for bounds in [NSRect(x: 100, y: 100, width: 900, height: 560), NSRect(x: 20, y: 30, width: 280, height: 180)] {
            for x in [bounds.minX, bounds.midX, bounds.maxX - 5] {
                for y in [bounds.minY, bounds.midY, bounds.maxY - 20] {
                    let anchor = NSRect(x: x, y: y, width: 5, height: 20)
                    let frame = HoverGeometry.frame(anchor: anchor, contentSize: NSSize(width: 620, height: 900), bounds: bounds)
                    XCTAssertTrue(bounds.contains(frame), "\(bounds) must contain \(frame)")
                    XCTAssertGreaterThan(frame.height, 0)
                    XCTAssertLessThanOrEqual(frame.height, 360)
                    if y == bounds.minY { XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY) }
                }
            }
        }
    }

    func testGlyphHitTestingDistinguishesEveryMemberAndIgnoresWhitespace() throws {
        let code = "const value = Config.logging.output.get();"
        let pane = CodePane()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        pane.show(lines: [CodeLine(number: 1, text: code, kind: .unchanged)], path: "main.ts", title: "", detail: "", showsHeader: false)
        pane.layoutSubtreeIfNeeded()
        let layout = try XCTUnwrap(pane.text.layoutManager)
        let container = try XCTUnwrap(pane.text.textContainer)
        layout.ensureLayout(for: container)
        for member in ["Config", "logging", "output", "get"] {
            let range = (code as NSString).range(of: member)
            // The far right of the last glyph must still resolve this member.
            let glyph = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let point = NSPoint(x: rect.minX + rect.width * 0.9 + pane.text.textContainerOrigin.x, y: rect.midY + pane.text.textContainerOrigin.y)
            XCTAssertEqual(pane.text.identifier(at: point), range)
        }
        XCTAssertNil(pane.text.identifier(at: NSPoint(x: 650, y: 25)))
        XCTAssertNil(CodeTextView.identifier(in: code as NSString, at: (code as NSString).range(of: ".").location))
        withExtendedLifetime(window) {}
    }

    func testNativeHoverPanelWrapsScrollsAndStaysInsideParentWindow() throws {
        let pane = CodePane()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = pane
        let presenter = InspectionPresenter()
        defer { presenter.dismiss(); withExtendedLifetime(window) {} }
        pane.show(lines: [CodeLine(number: 1, text: "const value = settings;", kind: .unchanged)], path: "main.ts", title: "", detail: "", showsHeader: false)
        pane.layoutSubtreeIfNeeded()
        let properties = (0..<100).map { "    property\($0): string;" }.joined(separator: "\n")
        presenter.show(.hover("```typescript\nconst settings: {\n" + properties + "\n}\n```"), kind: .hover, index: 16, textView: pane.text, root: URL(fileURLWithPath: "/tmp"))
        let panel = try XCTUnwrap(presenter.hoverPanel)
        XCTAssertTrue(window.frame.contains(panel.frame))
        XCTAssertTrue(panel.parent === window)
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] { (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) } }
        let scroll = try XCTUnwrap(find(NSScrollView.self, in: panel.contentView!).first)
        let text = try XCTUnwrap(scroll.documentView as? NSTextView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        XCTAssertGreaterThan(text.bounds.height, scroll.contentSize.height)
        XCTAssertFalse(text.string.contains("```"))
        let font = try XCTUnwrap(pane.text.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 12)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        XCTAssertNil(presenter.hoverPanel)
    }
    private func hoverFixture() throws -> (CodePane, NSWindow, InspectionPresenter) {
        let pane = CodePane()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        pane.show(lines: [CodeLine(number: 1, text: "const first = second;", kind: .unchanged)], path: "main.ts", title: "", detail: "", showsHeader: false)
        pane.layoutSubtreeIfNeeded()
        let presenter = InspectionPresenter()
        presenter.show(.hover("```typescript\nconst first: string\n```"), kind: .hover, index: 8, textView: pane.text, root: URL(fileURLWithPath: "/tmp"))
        XCTAssertNotNil(presenter.hoverPanel)
        return (pane, window, presenter)
    }

    func testLeavingHoverWaitsTwoSecondsWithoutRestartingOnFurtherMovement() throws {
        let (_, window, presenter) = try hoverFixture()
        defer { presenter.dismiss(); window.close() }
        let panel = try XCTUnwrap(presenter.hoverPanel)
        XCTAssertEqual(InspectionPresenter.hoverDismissDelay, 2)
        presenter.dismissHoverWhenPointerLeaves()
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertTrue(presenter.hoverPanel === panel)
        presenter.dismissHoverWhenPointerLeaves()
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertNil(presenter.hoverPanel, "Repeated movement outside must not extend the original two-second deadline")
    }

    func testEnteringHoverCancelsCloseAndLeavingStartsNewTwoSecondDeadline() throws {
        let (_, window, presenter) = try hoverFixture()
        defer { presenter.dismiss(); window.close() }
        let panel = try XCTUnwrap(presenter.hoverPanel)
        presenter.dismissHoverWhenPointerLeaves()
        presenter.hoverPointerMoved(to: NSPoint(x: panel.frame.midX, y: panel.frame.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        XCTAssertTrue(presenter.hoverPanel === panel, "Reading inside the panel must keep it open beyond two seconds")
        presenter.hoverPointerMoved(to: NSPoint(x: window.frame.maxX + 100, y: window.frame.minY))
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        XCTAssertNil(presenter.hoverPanel)
    }

    func testReturningToIdentifierAndReplacingHoverCancelOldCloseTask() throws {
        let (pane, window, presenter) = try hoverFixture()
        defer { presenter.dismiss(); window.close() }
        let firstPanel = try XCTUnwrap(presenter.hoverPanel)
        var range = NSRange(location: 6, length: 5)
        let anchor = pane.text.firstRect(forCharacterRange: range, actualRange: &range)
        presenter.dismissHoverWhenPointerLeaves()
        presenter.hoverPointerMoved(to: NSPoint(x: anchor.midX, y: anchor.midY))
        RunLoop.main.run(until: Date().addingTimeInterval(2.2))
        XCTAssertTrue(presenter.hoverPanel === firstPanel)
        presenter.dismissHoverWhenPointerLeaves()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        presenter.show(.hover("```typescript\nconst second: number\n```"), kind: .hover, index: 16, textView: pane.text, root: URL(fileURLWithPath: "/tmp"))
        let replacement = try XCTUnwrap(presenter.hoverPanel)
        XCTAssertFalse(replacement === firstPanel)
        RunLoop.main.run(until: Date().addingTimeInterval(2.1))
        XCTAssertTrue(presenter.hoverPanel === replacement, "A cancelled close task must not dismiss a replacement panel")
        presenter.show(.locations([]), kind: .references, index: 16, textView: pane.text, root: URL(fileURLWithPath: "/tmp"))
        XCTAssertNil(presenter.hoverPanel, "Opening another inspection panel dismisses the old hover immediately")
    }

    func testMovingBetweenIdentifierAndWhitespaceSchedulesExitInsteadOfImmediateInvalidation() throws {
        let (pane, window, presenter) = try hoverFixture()
        defer { presenter.dismiss(); window.close() }
        var invalidations = 0
        var exits = 0
        pane.text.onHoverInvalidated = { invalidations += 1 }
        pane.text.onHoverExited = { exits += 1 }
        func move(_ index: Int) throws {
            let layout = try XCTUnwrap(pane.text.layoutManager)
            let container = try XCTUnwrap(pane.text.textContainer)
            layout.ensureLayout(for: container)
            let glyph = layout.glyphIndexForCharacter(at: index)
            let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            let local = NSPoint(x: rect.midX + pane.text.textContainerOrigin.x, y: rect.midY + pane.text.textContainerOrigin.y)
            let point = pane.text.convert(local, to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
            pane.text.mouseMoved(with: event)
        }
        try move(8)
        try move(11)
        XCTAssertEqual(invalidations, 0)
        XCTAssertGreaterThanOrEqual(exits, 2)
        XCTAssertNil(pane.text.hoveredIdentifier)
        pane.text.cancelInspection()
        XCTAssertEqual(invalidations, 1, "Explicit invalidation must retain its immediate-dismiss behavior")
    }

    func testOpeningHistoryDismissesTypeHintWithoutDependingOnMouseEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-hover-action-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "interface Settings { port: number; }\n".write(to: root.appendingPathComponent("main.txt"), atomically: true, encoding: .utf8)
        let presenter = InspectionPresenter()
        let controller = WorkspaceController(history: isolatedHistoryStore(), inspection: presenter)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 920, height: 580))
        defer { controller.shutdown(); window.close() }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.explorer.outline.numberOfRows > 0 }, object: nil)], timeout: 10)
        controller.openFile("main.txt", diff: false)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.editor.right.text.string.contains("Settings") }, object: nil)], timeout: 10)
        workspace.layoutSubtreeIfNeeded()
        presenter.show(.hover("```typescript\ninterface Settings\n```"), kind: .hover, index: 12, textView: workspace.editor.right.text, root: root)
        XCTAssertNotNil(presenter.hoverPanel)
        controller.showHistory()
        XCTAssertNil(presenter.hoverPanel, "Native actions can bypass mouse monitors and must dismiss the hint themselves")
        XCTAssertTrue(controller.children.contains { $0 is WorkspaceHistorySidebar })
    }
}
