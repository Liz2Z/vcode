import AppKit
import XCTest
@testable import VCode

final class MarkdownPreviewTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private let source = """
    # Project guide

    Read **important** details and [documentation](https://example.com/docs).

    1. First
       - Nested
    2. Second

    ```typescript
    const value: string = "hello";
    ```
    """

    func testNativeMarkdownRetainsStructureLinksAndCodeColors() throws {
        let content = try MarkdownRenderer.render(source)
        let text = content.string as NSString
        XCTAssertFalse(content.string.contains("# Project"))
        XCTAssertFalse(content.string.contains("```"))
        XCTAssertTrue(content.string.contains("1. First"))
        XCTAssertTrue(content.string.contains("• Nested"), "An unordered nested list must not inherit its parent's numbering")
        XCTAssertTrue(content.string.contains("2. Second"))
        let title = text.range(of: "Project guide")
        let body = text.range(of: "Read")
        let titleFont = try XCTUnwrap(content.attribute(.font, at: title.location, effectiveRange: nil) as? NSFont)
        let bodyFont = try XCTUnwrap(content.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(titleFont.pointSize, bodyFont.pointSize)
        let link = text.range(of: "documentation")
        XCTAssertEqual((content.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com/docs")
        let keyword = text.range(of: "const")
        let literal = text.range(of: "hello")
        XCTAssertEqual((content.attribute(.font, at: keyword.location, effectiveRange: nil) as? NSFont)?.pointSize, 12)
        XCTAssertNotEqual(content.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor, content.attribute(.foregroundColor, at: literal.location, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(content.attribute(MarkdownRenderer.codeBlock, at: keyword.location, effectiveRange: nil) as? Bool, true)
    }

    func testSourceRangesFollowUnicodeInlineTokensAndFencedCode() throws {
        let source = "# 标题 😀\r\n\r\nRead **强调** and `value`.\r\n\r\n```ts\r\nconst value = 1;\r\n```\r\n"
        let content = try MarkdownRenderer.render(source)
        for token in ["标题 😀", "强调", "value"] {
            let rendered = (content.string as NSString).range(of: token)
            let span = try XCTUnwrap(content.attribute(MarkdownRenderer.sourceRange, at: rendered.location, effectiveRange: nil) as? NSValue)
            XCTAssertEqual((source as NSString).substring(with: span.rangeValue), token)
        }
        let code = (content.string as NSString).range(of: "const value = 1;")
        let span = try XCTUnwrap(content.attribute(MarkdownRenderer.sourceRange, at: code.location, effectiveRange: nil) as? NSValue)
        XCTAssertTrue((source as NSString).substring(with: span.rangeValue).contains("const value = 1;"))
    }

    func testViewportAnchorSurvivesReflowAndContentInsertedAboveIt() throws {
        let preview = MarkdownPreview()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = preview
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        func settle() {
            let limit = Date().addingTimeInterval(3)
            while preview.isRendering && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(preview.isRendering)
            preview.layoutSubtreeIfNeeded()
        }
        let source = (0..<40).map { "## Section \($0)\n\n" + "Paragraph \($0) " + String(repeating: "words to wrap around the viewport ", count: 8) }.joined(separator: "\n\n")
        window.setContentSize(NSSize(width: 520, height: 300))
        preview.show(source); settle()
        XCTAssertGreaterThan(preview.scroll.frame.width, 450)
        XCTAssertGreaterThan(preview.scroll.frame.height, 250)
        preview.scroll.contentView.scroll(to: NSPoint(x: 0, y: 920))
        let original = try XCTUnwrap(preview.readingPosition())
        let anchor = try XCTUnwrap(original.top)
        preview.clear()
        window.setContentSize(NSSize(width: 300, height: 300))
        let updated = "# Inserted heading\n\nInserted paragraph.\n\n" + source
        preview.show(updated, restoring: original)
        XCTAssertEqual(preview.readingPosition()?.top, anchor, "Rendering must expose the pending content position, not temporary empty layout")
        preview.show(updated + "\n\nRefreshed footer.", restoring: preview.readingPosition())
        settle()
        let restored = try XCTUnwrap(preview.readingPosition())
        XCTAssertEqual(restored.top?.text, anchor.text)
        XCTAssertEqual(restored.top?.line, anchor.line + 4)
        XCTAssertGreaterThan(restored.y, original.y, "Narrower paragraphs and inserted content change pixels while retaining the same content")
        XCTAssertEqual(restored.verticalOffset, original.verticalOffset, accuracy: 1)
        preview.show("# Stale"); preview.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertNil(preview.readingPosition())
    }

    func testMarkdownModesRefreshAndClosingCannotLeakOldPreview() throws {
        let editor = EditorView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        func snapshot(_ source: String, comparison: GitComparison? = nil) -> FileSnapshot {
            FileSnapshot(path: "README.md", before: "# Before", after: source, rows: [], message: nil, isBinary: false, comparison: comparison)
        }
        editor.prepare(path: "README.md", diff: false, isGit: true)
        editor.show(snapshot(source), diff: false, preserveScroll: false)
        XCTAssertTrue(editor.showingMarkdownPreview)
        XCTAssertFalse(editor.breadcrumbs.previewButton.isHidden)
        XCTAssertTrue(editor.breadcrumbs.previewButton.isSelected)
        editor.showMarkdownSource()
        XCTAssertFalse(editor.showingMarkdownPreview)
        XCTAssertEqual(editor.right.text.string, source + "\n")
        editor.show(snapshot("# Updated"), diff: false, preserveScroll: true)
        XCTAssertFalse(editor.showingMarkdownPreview, "Refresh must preserve the chosen reading mode")
        editor.showMarkdownPreview()
        let deadline = Date().addingTimeInterval(3)
        while editor.markdown.isRendering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(editor.markdown.text.string, "Updated")
        XCTAssertTrue(editor.closeActiveTab())
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(editor.markdown.text.string.isEmpty)
        XCTAssertFalse(editor.showingMarkdownPreview)
        XCTAssertFalse(editor.welcome.isHidden)
        editor.prepare(path: "README.md", diff: true, isGit: true, comparison: .unstaged)
        editor.show(snapshot(source, comparison: .unstaged), diff: true, preserveScroll: false)
        XCTAssertFalse(editor.showingMarkdownPreview, "Markdown diffs must keep the ordinary two-column comparison")
        XCTAssertTrue(editor.breadcrumbs.previewButton.isHidden)
    }

    func testLongPreviewWrapsScrollsAndRejectsCompletionAfterClear() throws {
        let preview = MarkdownPreview(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        let window = NSWindow(contentRect: preview.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = preview
        preview.layoutSubtreeIfNeeded()
        preview.show(String(repeating: "## Section\n\nA long paragraph with enough words to wrap in a narrow window.\n\n", count: 40))
        let deadline = Date().addingTimeInterval(3)
        while preview.isRendering && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(preview.isRendering)
        XCTAssertGreaterThan(preview.text.frame.height, preview.scroll.contentSize.height)
        XCTAssertLessThanOrEqual(preview.text.frame.width, preview.scroll.contentSize.width)
        preview.show(source)
        preview.clear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(preview.text.string.isEmpty)
        XCTAssertFalse(preview.isRendering)
    }
}
