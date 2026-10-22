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
}
