import XCTest
@testable import VCode

final class ReaderSessionTests: XCTestCase {
    func testReopeningAndClosingDocumentsPreservesSelection() {
        var session = ReaderSession()
        session.open("src/first.ts")
        session.open("src/second.ts")
        session.open("src/third.ts")
        session.open("src/second.ts")
        XCTAssertEqual(session.paths.count, 3)
        XCTAssertFalse(session.close("src/first.ts"))
        XCTAssertEqual(session.activePath, "src/second.ts")
        XCTAssertTrue(session.close("src/second.ts"))
        XCTAssertEqual(session.activePath, "src/third.ts")
        XCTAssertTrue(session.close("src/third.ts"))
        XCTAssertNil(session.activePath)
        XCTAssertTrue(session.paths.isEmpty)
    }

    func testSourceStagedAndUnstagedKeepIndependentTabsAndCloseTargets() {
        var session = ReaderSession()
        session.open("shared.ts")
        session.open("shared.ts", comparison: .staged)
        session.open("shared.ts", comparison: .unstaged)
        XCTAssertEqual(session.documents.count, 3)
        XCTAssertFalse(session.close(ReadingDocument(path: "shared.ts", comparison: .staged)))
        XCTAssertEqual(session.activeDocument?.comparison, .unstaged)
        XCTAssertTrue(session.close(ReadingDocument(path: "shared.ts", comparison: .unstaged)))
        XCTAssertEqual(session.documents.count, 1)
        XCTAssertNil(session.activeDocument?.comparison)
        XCTAssertEqual(session.activePath, "shared.ts")
    }

    func testResetCannotLeaveAnActiveDocumentFromThePreviousWorkspace() {
        var session = ReaderSession()
        session.open("previous.ts")
        session.reset()
        XCTAssertNil(session.activePath)
        session.open("new.ts")
        XCTAssertEqual(session.paths, ["new.ts"])
        XCTAssertEqual(session.activePath, "new.ts")
    }

    func testRelativeClosingUsesContextTabAndPreservesSurvivingActiveDocument() {
        for scope in [ReadingCloseScope.left, .right, .others, .all] {
            var session = ReaderSession()
            for path in ["a.ts", "b.ts", "c.ts", "d.ts"] { session.open(path) }
            let reference = session.documents[1]
            session.open("c.ts")
            let changed = session.close(scope, relativeTo: reference)
            switch scope {
            case .left:
                XCTAssertEqual(session.paths, ["b.ts", "c.ts", "d.ts"])
                XCTAssertEqual(session.activePath, "c.ts")
                XCTAssertFalse(changed)
            case .right, .others:
                XCTAssertEqual(session.paths, scope == .right ? ["a.ts", "b.ts"] : ["b.ts"])
                XCTAssertEqual(session.activeDocument, reference)
                XCTAssertTrue(changed)
            case .all:
                XCTAssertTrue(session.documents.isEmpty)
                XCTAssertNil(session.activeDocument)
                XCTAssertTrue(changed)
            }
        }
    }

    func testMovingTabsKeepsActiveComparisonAndRelativeClosuresFollowNewOrder() {
        var session = ReaderSession()
        session.open("shared.ts")
        session.open("shared.ts", comparison: .staged)
        session.open("shared.ts", comparison: .unstaged)
        session.open("last.ts")
        let source = session.documents[0], staged = session.documents[1], unstaged = session.documents[2], last = session.documents[3]
        session.open("shared.ts", comparison: .staged)
        XCTAssertTrue(session.move(last, to: 0))
        XCTAssertEqual(session.documents, [last, source, staged, unstaged])
        XCTAssertTrue(session.move(source, to: 4))
        XCTAssertEqual(session.documents, [last, staged, unstaged, source])
        XCTAssertEqual(session.activeDocument, staged)
        session.open("shared.ts", comparison: .staged)
        XCTAssertEqual(session.documents, [last, staged, unstaged, source], "Reopening must not undo ordering")
        XCTAssertFalse(session.close(.right, relativeTo: staged))
        XCTAssertEqual(session.documents, [last, staged])
        XCTAssertEqual(session.activeDocument, staged)
        XCTAssertFalse(session.close(.left, relativeTo: staged))
        XCTAssertEqual(session.documents, [staged])
    }

    func testInvalidOrCancelledReorderAndStaleMenuReferenceCannotChangeSession() {
        var session = ReaderSession()
        session.open("a.ts"); session.open("b.ts")
        let before = session.documents, active = session.activeDocument
        XCTAssertFalse(session.move(before[0], to: 0))
        XCTAssertFalse(session.move(before[0], to: 1))
        XCTAssertFalse(session.move(before[0], to: -1))
        XCTAssertFalse(session.move(before[0], to: 3))
        let stale = ReadingDocument(path: "closed.ts", comparison: nil)
        XCTAssertFalse(session.move(stale, to: 0))
        XCTAssertFalse(session.close(.all, relativeTo: stale))
        XCTAssertEqual(session.documents, before)
        XCTAssertEqual(session.activeDocument, active)
    }

    func testClosingFollowsActivationOrderRatherThanAdjacentTabsOrTabReordering() {
        var session = ReaderSession()
        for path in ["a.ts", "b.ts", "c.ts", "d.ts"] { session.open(path) }
        session.open("b.ts")
        session.open("a.ts")
        XCTAssertTrue(session.move(session.documents[1], to: 4))
        XCTAssertEqual(session.paths, ["a.ts", "c.ts", "d.ts", "b.ts"])
        for (closed, expected) in [("a.ts", "b.ts"), ("b.ts", "d.ts"), ("d.ts", "c.ts")] {
            XCTAssertTrue(session.close(closed))
            XCTAssertEqual(session.activePath, expected)
        }
        XCTAssertTrue(session.close("c.ts"))
        XCTAssertNil(session.activeDocument)
    }

    func testBatchCloseSkipsClosedHistoryAndKeepsSurvivingActiveTab() {
        var session = ReaderSession()
        for path in ["a.ts", "b.ts", "c.ts", "d.ts"] { session.open(path) }
        session.open("a.ts"); session.open("c.ts")
        XCTAssertFalse(session.close("a.ts"))
        XCTAssertEqual(session.activePath, "c.ts")
        XCTAssertTrue(session.close([session.documents[0], session.documents[1]]))
        XCTAssertEqual(session.activePath, "d.ts")
        XCTAssertEqual(session.paths, ["d.ts"])
    }

    func testComparisonAndDraftActivationHaveIndependentIdentities() {
        var session = ReaderSession()
        let source = ReadingDocument(path: "same.ts", comparison: nil)
        let staged = ReadingDocument(path: "same.ts", comparison: .staged)
        let unstaged = ReadingDocument(path: "same.ts", comparison: .unstaged)
        let draft = ReadingDocument(path: "Untitled-1", comparison: nil, draftID: UUID())
        for document in [source, staged, unstaged, draft, source, draft] { session.open(document) }
        XCTAssertTrue(session.close(draft)); XCTAssertEqual(session.activeDocument, source)
        XCTAssertTrue(session.close(source)); XCTAssertEqual(session.activeDocument, unstaged)
        XCTAssertTrue(session.close(unstaged)); XCTAssertEqual(session.activeDocument, staged)
    }

    func testRestoreRenameAndResetCannotLeaveStaleActivationTargets() {
        var session = ReaderSession()
        let a = ReadingDocument(path: "a.ts", comparison: nil)
        let b = ReadingDocument(path: "b.ts", comparison: nil)
        let c = ReadingDocument(path: "c.ts", comparison: nil)
        session.open("old.ts")
        session.restore(documents: [a, b, c, b], active: b)
        session.open(a); session.open(c)
        session.renamePaths(["a.ts": "renamed.ts"])
        XCTAssertTrue(session.close(c)); XCTAssertEqual(session.activePath, "renamed.ts")
        XCTAssertTrue(session.close("renamed.ts")); XCTAssertEqual(session.activeDocument, b)
        session.reset()
        session.open("new.ts")
        XCTAssertTrue(session.close("new.ts")); XCTAssertNil(session.activeDocument)
        XCTAssertTrue(session.documents.isEmpty)
    }
}
