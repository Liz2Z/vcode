import XCTest
@testable import VCode

final class DiffTests: XCTestCase {
    func testUnequalReplacementPreservesAlignmentAndContext() throws {
        let rows = try Diff.align(before: "first\nold\nlast\n", after: "first\nnew\nextra\nlast\n", patch: "@@ -2 +2,2 @@\n-old\n+new\n+extra\n")
        XCTAssertEqual(rows.map(\.left.number), [1, 2, nil, 3])
        XCTAssertEqual(rows.map(\.right.number), [1, 2, 3, 4])
        XCTAssertEqual(rows[2].left.kind, .placeholder)
        XCTAssertEqual(rows.last?.left.text, "last")
        XCTAssertEqual(rows.last?.right.text, "last")
    }

    func testInsertionAtStartAndEnd() throws {
        let rows = try Diff.align(before: "middle\n", after: "start\nmiddle\nend\n", patch: "@@ -0,0 +1 @@\n+start\n@@ -1,0 +3 @@\n+end\n")
        XCTAssertEqual(rows.map(\.left.number), [nil, 1, nil])
        XCTAssertEqual(rows.map(\.right.text), ["start", "middle", "end"])
    }

    func testWholeFileAddAndDelete() throws {
        let added = try Diff.align(before: "", after: "你好\n🙂\n", patch: "@@ -0,0 +1,2 @@\n+你好\n+🙂\n")
        XCTAssertEqual(added.map(\.right.kind), [.added, .added])
        XCTAssertTrue(added.allSatisfy { $0.left.number == nil })
        let deleted = try Diff.align(before: "a\nb\n", after: "", patch: "@@ -1,2 +0,0 @@\n-a\n-b\n")
        XCTAssertEqual(deleted.map(\.left.kind), [.removed, .removed])
        XCTAssertTrue(deleted.allSatisfy { $0.right.number == nil })
    }

    func testEmptyAndMissingFinalNewline() throws {
        XCTAssertEqual(try Diff.align(before: "", after: "", patch: ""), [])
        let rows = try Diff.align(before: "a", after: "a\n", patch: "@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+a\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].left.text, "a")
        XCTAssertEqual(rows[0].right.text, "a")
    }

    func testInvalidHunksFailInsteadOfShowingWrongLineNumbers() {
        XCTAssertThrowsError(try Diff.align(before: "a\n", after: "a\nb\n", patch: ""))
        XCTAssertThrowsError(try Diff.align(before: "a\n", after: "b\n", patch: "@@ -99 +1 @@\n"))
        XCTAssertThrowsError(try Diff.align(before: "a\n", after: "b\n", patch: "@@ invalid @@\n"))
    }

    func testCRLFAndBlankLines() {
        XCTAssertEqual(Diff.lines("a\r\n\r\nb\r\n"), ["a", "", "b"])
        XCTAssertEqual(Diff.lines("\n"), [""])
        XCTAssertEqual(Diff.lines("a\n\n"), ["a", ""])
    }
}
