import AppKit
import XCTest
@testable import VCode

final class CodeViewportTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testFractionalDiffScrollingDoesNotPaintLineNumbersIntoFixedHeader() throws {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.setContentSize(NSSize(width: 1280, height: 540))
        editor.layoutSubtreeIfNeeded()
        defer { withExtendedLifetime(window) {} }
        let rows = (1...400).map { (number: Int) in
            DiffRow(left: CodeLine(number: number, text: "export const entry\(number) = 1;", kind: .removed),
                    right: CodeLine(number: number, text: "export const entry\(number) = 2;", kind: .added))
        }
        editor.prepare(path: "boundary.ts", diff: true, isGit: true)
        editor.show(FileSnapshot(path: "boundary.ts", before: "old", after: "new", rows: rows, message: nil, isBinary: false), diff: true, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        for pane in [editor.left, editor.right] {
            if let container = pane.text.textContainer { pane.text.layoutManager?.ensureLayout(for: container) }
        }

        func headerPixels(_ pane: CodePane) throws -> [UInt8] {
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            let scaleX = CGFloat(bitmap.pixelsWide) / pane.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / pane.bounds.height
            let firstY = Int((pane.bounds.maxY - pane.scroll.frame.maxY - 7) * scaleY)
            let endY = Int((pane.bounds.maxY - pane.scroll.frame.maxY - 1) * scaleY)
            var pixels: [UInt8] = []
            for y in firstY..<endY {
                for x in 0..<Int(55 * scaleX) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    pixels += [color.redComponent, color.greenComponent, color.blueComponent].map { UInt8(round($0 * 255)) }
                }
            }
            return pixels
        }
        let initial = try [editor.left, editor.right].map(headerPixels)
        for y: CGFloat in [2380, 2387.5, 2391, 2402.5] {
            let clip = editor.right.scroll.contentView
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
            editor.right.scroll.reflectScrolledClipView(clip)
            editor.layoutSubtreeIfNeeded()
            XCTAssertEqual(editor.left.scroll.contentView.bounds.minY, clip.bounds.minY, accuracy: 0.1)
            for (index, pane) in [editor.left, editor.right].enumerated() {
                XCTAssertTrue(try headerPixels(pane) == initial[index], "Scrolling to \(y) must leave the fixed header untouched")
            }
        }
    }

    func testOpeningAndReopeningShortJSONShowsOpeningBraceAndFirstKey() throws {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.setContentSize(NSSize(width: 640, height: 540))
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); withExtendedLifetime(window) {} }
        let json = "{\"name\":\"resource-preview\",\"private\":true}"
        for path in ["package.json", "tsconfig.json", "package.json", "settings.json", "package.json"] {
            editor.prepare(path: path, diff: false, isGit: false)
            editor.show(FileSnapshot(path: path, before: "", after: json, rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
            editor.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            try assertLeadingTextVisible(editor.right, path: path)
        }
    }

    func testNewFileDoesNotInheritPreviousFilesHorizontalScroll() throws {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.setContentSize(NSSize(width: 640, height: 540))
        defer { withExtendedLifetime(window) {} }
        editor.prepare(path: "wide.ts", diff: false, isGit: false)
        editor.show(FileSnapshot(path: "wide.ts", before: "", after: "const value = '" + String(repeating: "wide ", count: 200) + "';", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        editor.right.scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        editor.right.scroll.reflectScrolledClipView(editor.right.scroll.contentView)
        XCTAssertGreaterThan(editor.right.scroll.contentView.bounds.minX, 100)
        editor.prepare(path: "package.json", diff: false, isGit: false)
        editor.show(FileSnapshot(path: "package.json", before: "", after: "{\"name\":\"resource-preview\",\"private\":true}", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        try assertLeadingTextVisible(editor.right, path: "package.json after horizontal scroll")
        // A long new JSON file cannot rely on a short document shrinking/clamping
        // the previous scroll position on its own.
        editor.prepare(path: "wide.ts", diff: false, isGit: false)
        editor.show(FileSnapshot(path: "wide.ts", before: "", after: "const value = '" + String(repeating: "wide ", count: 200) + "';", rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        editor.right.scroll.contentView.scroll(to: NSPoint(x: 200, y: 0))
        let longJSON = "{\"data\":\"" + String(repeating: "value ", count: 200) + "\"}"
        editor.prepare(path: "long.json", diff: false, isGit: false)
        editor.show(FileSnapshot(path: "long.json", before: "", after: longJSON, rows: [], message: nil, isBinary: false), diff: false, preserveScroll: false)
        editor.layoutSubtreeIfNeeded()
        try assertLeadingTextVisible(editor.right, path: "long.json after horizontal scroll")
    }

    func testJSONRefreshAndSourceDiffTransitionsKeepTextOutsideRuler() throws {
        let editor = EditorView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 540), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = editor
        window.setContentSize(NSSize(width: 1280, height: 540))
        defer { withExtendedLifetime(window) {} }
        for diff in [false, true, false, true, false] {
            editor.prepare(path: "package.json", diff: diff, isGit: true)
            for version in 1...2 {
                let before = "{\"name\":\"previous\",\"version\":0}"
                let after = "{\"name\":\"current\",\"version\":\(version)}"
                let rows = [DiffRow(left: CodeLine(number: 1, text: before, kind: .removed), right: CodeLine(number: 1, text: after, kind: .added))]
                editor.show(FileSnapshot(path: "package.json", before: before, after: after, rows: rows, message: nil, isBinary: false), diff: diff, preserveScroll: version > 1)
                editor.layoutSubtreeIfNeeded()
                try assertLeadingTextVisible(editor.right, path: "JSON source/diff refresh")
                if diff { try assertLeadingTextVisible(editor.left, path: "JSON original refresh") }
            }
        }
    }

    private func assertLeadingTextVisible(_ pane: CodePane, path: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let layout = try XCTUnwrap(pane.text.layoutManager)
        let container = try XCTUnwrap(pane.text.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphRange(forCharacterRange: NSRange(location: 0, length: 7), actualCharacterRange: nil)
        let opening = layout.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: pane.text.textContainerOrigin.x, dy: pane.text.textContainerOrigin.y)
        XCTAssertGreaterThan(pane.scroll.contentView.bounds.width, 300, file: file, line: line)
        XCTAssertTrue(pane.text.visibleRect.contains(opening), "\(path): opening brace and first key must be visible", file: file, line: line)
        let openingInPane = pane.text.convert(opening, to: pane)
        let gutterInPane = pane.gutter.convert(pane.gutter.bounds, to: pane)
        XCTAssertGreaterThanOrEqual(openingInPane.minX, gutterInPane.maxX + 5, "Opening text must not lie behind the gutter", file: file, line: line)
        if let output = ProcessInfo.processInfo.environment["VCODE_JSON_SNAPSHOT"], path == "package.json" {
            let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
            pane.cacheDisplay(in: pane.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
        }
    }
}
