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
}
