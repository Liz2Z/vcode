import XCTest
@testable import VCode

final class LSPInspectionMapperTests: XCTestCase {
    func testDocumentHighlightsPreserveBothUTF16Endpoints() throws {
        let raw: [[String: Any]] = [
            ["range": ["start": ["line": 1, "character": 17], "end": ["line": 1, "character": 24]], "kind": 3],
            ["range": ["start": ["line": 2, "character": 8], "end": ["line": 1, "character": 9]]]
        ]
        guard case .highlights(let highlights) = try LSPInspectionMapper.decode(raw, kind: .documentHighlight) else { return XCTFail("Expected highlights") }
        XCTAssertEqual(highlights, [SymbolOccurrence(startLine: 1, startCharacter: 17, endLine: 1, endCharacter: 24)])
        guard case .highlights(let empty) = try LSPInspectionMapper.decode(NSNull(), kind: .documentHighlight) else { return XCTFail("Expected empty highlights") }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertThrowsError(try LSPInspectionMapper.decode(42, kind: .documentHighlight))
    }
    func testHoverAcceptsMarkupAndMarkedStringArrays() throws {
        let raw: [String: Any] = ["contents": ["A type", ["language": "typescript", "value": "const value: number"], ["kind": "plaintext", "value": "Documentation"]]]
        guard case .hover(let text) = try LSPInspectionMapper.decode(raw, kind: .hover) else { return XCTFail("Expected hover") }
        XCTAssertEqual(text, "A type\n\n```typescript\nconst value: number\n```\n\nDocumentation")
        guard case .hover(let empty) = try LSPInspectionMapper.decode(NSNull(), kind: .hover) else { return XCTFail("Expected empty hover") }
        XCTAssertTrue(empty.isEmpty)
        XCTAssertThrowsError(try LSPInspectionMapper.decode(["contents": 42], kind: .hover))
    }

    func testLocationsAndLinksPreserveUTF16PositionsAndIgnoreInvalidTargets() throws {
        let position: [String: Any] = ["start": ["line": 5, "character": 19], "end": ["line": 5, "character": 25]]
        let raw: [[String: Any]] = [
            ["uri": "file:///tmp/model.ts", "range": position],
            ["targetUri": "file:///tmp/linked.ts", "targetSelectionRange": position, "targetRange": ["start": ["line": 0, "character": 0]]],
            ["uri": "https://example.com/model.ts", "range": position],
            ["uri": "file:///tmp/invalid.ts", "range": ["start": ["line": -1, "character": 0]]]
        ]
        guard case .locations(let locations) = try LSPInspectionMapper.decode(raw, kind: .definition) else { return XCTFail("Expected locations") }
        XCTAssertEqual(locations.map(\.url.lastPathComponent), ["model.ts", "linked.ts"])
        XCTAssertEqual(locations.map(\.line), [5, 5])
        XCTAssertEqual(locations.map(\.character), [19, 19])
        guard case .locations(let single) = try LSPInspectionMapper.decode(raw[0], kind: .definition) else { return XCTFail("Expected single location") }
        XCTAssertEqual(single.count, 1)
        guard case .locations(let empty) = try LSPInspectionMapper.decode(NSNull(), kind: .references) else { return XCTFail("Expected empty locations") }
        XCTAssertTrue(empty.isEmpty)
    }
}
