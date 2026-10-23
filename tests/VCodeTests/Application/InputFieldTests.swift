import AppKit
import XCTest
@testable import VCode

final class InputFieldTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testSearchAndTextContentsStayCenteredAcrossInputSizes() throws {
        for height in [26.0, 28, 30] {
            for width in [180.0, 500] {
                for size in [12.0, 13] {
                    for value in ["", "Filter files", "文件 / example.ts"] {
                        let search = Theme.searchField()
                        let text = Theme.textField()
                        for field in [search, text] {
                            field.frame = NSRect(x: 0, y: 0, width: width, height: height)
                            field.font = .systemFont(ofSize: size)
                            field.stringValue = value
                            field.placeholderString = "Filter files"
                            XCTAssertEqual(field.bezelStyle, .squareBezel)
                            let rect = field === search ? search.searchTextBounds : try XCTUnwrap(field.cell).drawingRect(forBounds: field.bounds)
                            XCTAssertEqual(rect.midY, field.bounds.midY, accuracy: 0.5)
                            XCTAssertEqual(rect.height, ceil(NSLayoutManager().defaultLineHeight(for: field.font!)), accuracy: 0.5)
                            XCTAssertTrue(field.bounds.contains(rect))
                        }
                        XCTAssertEqual(search.searchButtonBounds.midY, search.bounds.midY, accuracy: 0.5)
                        XCTAssertEqual(search.cancelButtonBounds.midY, search.bounds.midY, accuracy: 0.5)
                        XCTAssertGreaterThan(search.searchTextBounds.minX, search.searchButtonBounds.minX)
                        XCTAssertLessThanOrEqual(search.searchTextBounds.maxX, search.cancelButtonBounds.minX)
                    }
                }
            }
        }
    }

    func testNativeFieldEditorSharesCenteredTextBounds() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.makeFirstResponder(nil); window.close() }
        for field in [Theme.searchField() as NSTextField, Theme.textField()] {
            field.frame = NSRect(x: 20, y: 50, width: 300, height: 30)
            field.font = .systemFont(ofSize: 12)
            field.stringValue = "Filter files"
            window.contentView?.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            let rect = field.convert(editor.visibleRect, from: editor)
            XCTAssertEqual(rect.midY, field.bounds.midY, accuracy: 1)
            XCTAssertTrue(field.bounds.contains(rect))
            XCTAssertEqual(editor.string, "Filter files")
            editor.setSelectedRange(NSRange(location: 3, length: 2))
            XCTAssertEqual(editor.selectedRange(), NSRange(location: 3, length: 2))
            window.makeFirstResponder(nil)
            field.removeFromSuperview()
        }
    }
}
