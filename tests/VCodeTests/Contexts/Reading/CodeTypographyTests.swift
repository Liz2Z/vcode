import AppKit
import XCTest
@testable import VCode

final class CodeTypographyTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testNativeLayoutCentersBothSupportedFontsInsideFixedRows() throws {
        for name in ["Monaco", "Menlo"] {
            let font = try XCTUnwrap(NSFont(name: name, size: 12))
            let storage = NSTextStorage(string: "program\n.enablePositionalOptions()\n.name(\"idev\")\n")
            Syntax.apply(to: storage, path: "main.ts", font: font)
            let layout = CodeLayoutManager()
            layout.codeFont = font
            layout.usesFontLeading = false
            let container = NSTextContainer(size: NSSize(width: 1000, height: 1000))
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            for index in [0, 8, 35] {
                let glyph = layout.glyphIndexForCharacter(at: index)
                let row = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let baseline = layout.location(forGlyphAt: glyph).y
                let above = baseline - font.ascender
                let below = row.height - (baseline - font.descender)
                XCTAssertEqual(row.height, 20, accuracy: 0.001)
                XCTAssertEqual(above, below, accuracy: 0.001, "\(name) must distribute line padding evenly")
                XCTAssertGreaterThanOrEqual(above, 0)
            }
        }
    }

    func testFallbackGlyphsKeepBaselineAndDiffRowGeometry() throws {
        let pane = CodePane(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        pane.show(lines: [
            CodeLine(number: 1, text: "program", kind: .unchanged),
            CodeLine(number: nil, text: "", kind: .placeholder),
            CodeLine(number: 2, text: "中文类型🙂 value", kind: .added),
            CodeLine(number: 3, text: ".name(\"idev\")", kind: .removed)
        ], path: "main.ts", title: "Modified", detail: "WORKING TREE")
        let layout = try XCTUnwrap(pane.text.layoutManager)
        layout.ensureLayout(for: try XCTUnwrap(pane.text.textContainer))
        let first = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: 0)).y
        for row in [2, 3] {
            let glyph = layout.glyphIndexForCharacter(at: pane.offsets[row])
            // Font fallback can optically offset an individual CJK glyph by a
            // fraction of a point; it must not shift the row or Latin baseline.
            XCTAssertEqual(layout.location(forGlyphAt: glyph).y, first, accuracy: 0.5)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertEqual(rect.minY, CGFloat(row) * 20, accuracy: 0.001)
            XCTAssertEqual(rect.height, 20, accuracy: 0.001)
        }
        let latin = (pane.text.string as NSString).range(of: "value")
        XCTAssertEqual(layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: latin.location)).y, first, accuracy: 0.001)
        // Pointer hit testing must use the same shifted layout as the painted text.
        let range = (pane.text.string as NSString).range(of: "name")
        let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: try XCTUnwrap(pane.text.textContainer))
        let point = NSPoint(x: rect.midX + pane.text.textContainerOrigin.x, y: rect.midY + pane.text.textContainerOrigin.y)
        XCTAssertEqual(pane.text.identifier(at: point), range)
    }
}
