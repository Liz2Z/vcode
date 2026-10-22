import AppKit
import XCTest
@testable import VCode

final class NavigationFlashTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func fixture() -> (CodePane, NSWindow) {
        let pane = CodePane()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 430), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane
        pane.show(lines: [
            CodeLine(number: 1, text: "// 🙂 Types", kind: .unchanged),
            CodeLine(number: nil, text: "", kind: .placeholder),
            CodeLine(number: 2, text: "export interface Payload { value: string; }", kind: .added),
            CodeLine(number: 3, text: "export const count: number = 1;", kind: .unchanged)
        ], path: "main.ts", title: "Modified", detail: "WORKING TREE")
        pane.layoutSubtreeIfNeeded()
        return (pane, window)
    }

    func testDestinationHighlightsCorrectUTF16RangeWithoutChangingSourceStyleOrCaret() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelNavigationFlash(); window.close() }
        let original = try XCTUnwrap(pane.text.textStorage).copy() as! NSAttributedString
        pane.reveal(line: 1, character: 17)
        XCTAssertNil(pane.text.navigationFlashRange, "Ordinary file positioning must not flash")
        pane.reveal(line: 1, character: 17, highlightDestination: true)
        let range = try XCTUnwrap(pane.text.navigationFlashRange)
        XCTAssertEqual((pane.text.string as NSString).substring(with: range), "Payload")
        XCTAssertEqual(range.location, pane.offsets[2] + 17)
        XCTAssertEqual(pane.text.selectedRange(), NSRange(location: range.location, length: 0))
        XCTAssertEqual(pane.position(at: pane.text.selectedRange().location)?.line, 1)
        XCTAssertTrue(original.isEqual(to: try XCTUnwrap(pane.text.textStorage)))
        XCTAssertEqual((pane.text.layoutManager as? CodeLayoutManager)?.navigationRange, range)
    }

    func testFlashPulsesAndClearsAfterTwoSeconds() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelNavigationFlash(); window.close() }
        pane.reveal(line: 1, character: 17, highlightDestination: true)
        let layout = try XCTUnwrap(pane.text.layoutManager as? CodeLayoutManager)
        let initial = layout.navigationAlpha
        XCTAssertEqual(CodeTextView.navigationFlashDuration, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNotNil(pane.text.navigationFlashRange)
        XCTAssertLessThan(layout.navigationAlpha, initial)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { XCTAssertEqual(layout.navigationAlpha, 0, "The off phase must remove the background, not merely dim it") }
        RunLoop.main.run(until: Date().addingTimeInterval(1.8))
        XCTAssertNil(pane.text.navigationFlashRange)
        XCTAssertNil(layout.navigationRange)
    }

    func testRapidNavigationReplacesOldFlashAndFileReplacementCancelsIt() throws {
        let (pane, window) = fixture()
        defer { pane.text.cancelNavigationFlash(); window.close() }
        pane.reveal(line: 1, character: 17, highlightDestination: true)
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        pane.reveal(line: 2, character: 13, highlightDestination: true)
        let next = try XCTUnwrap(pane.text.navigationFlashRange)
        XCTAssertEqual((pane.text.string as NSString).substring(with: next), "count")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertEqual(pane.text.navigationFlashRange, next, "The original two-second deadline must not clear the second jump")
        pane.show(lines: [CodeLine(number: 1, text: "export const other = 3;", kind: .unchanged)], path: "other.ts", title: "", detail: "")
        XCTAssertNil(pane.text.navigationFlashRange)
        XCTAssertNil((pane.text.layoutManager as? CodeLayoutManager)?.navigationRange)
        pane.text.flashNavigation(at: -1)
        pane.text.flashNavigation(at: pane.text.string.utf16.count)
        XCTAssertNil(pane.text.navigationFlashRange)
    }
}
