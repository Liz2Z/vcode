import XCTest
@testable import VCode

final class WorkspaceReaderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "VCode Tests"])
        try git(["config", "user.email", "tests@localhost"])
        try git(["config", "commit.gpgsign", "false"])
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testWorkingTreeIncludesStagedUnstagedUntrackedAndDeletedFiles() throws {
        try write("src/main.ts", "export const answer = 1;\n")
        try write("remove.ts", "gone\n")
        try write(".gitignore", "ignored/\n")
        try git(["add", "."])
        try git(["commit", "-qm", "initial"])
        try write("src/main.ts", "export const answer = 2;\n")
        try git(["add", "src/main.ts"])
        try write("src/main.ts", "export const answer = 3;\n")
        try write("new folder/中文 file.ts", "const greeting = '你好';\n")
        try write("ignored/file.ts", "hidden\n")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("remove.ts"))
        let reader = try WorkspaceReader(folder: folder.appendingPathComponent("src"))
        let state = try reader.load()
        XCTAssertEqual(reader.root.path, folder.resolvingSymlinksInPath().path)
        XCTAssertEqual(state.branch, "main")
        XCTAssertEqual(Set(state.changes.map(\.path)), ["src/main.ts", "remove.ts", "new folder/中文 file.ts"])
        XCTAssertFalse(state.files.contains("ignored/file.ts"))
        let snapshot = try reader.snapshot(path: "src/main.ts", state: state, compare: true)
        XCTAssertEqual(snapshot.before, "export const answer = 1;\n")
        XCTAssertEqual(snapshot.after, "export const answer = 3;\n")
        XCTAssertEqual(snapshot.additions, 1)
        XCTAssertEqual(snapshot.deletions, 1)
        let deleted = try reader.snapshot(path: "remove.ts", state: state, compare: true)
        XCTAssertEqual(deleted.after, "")
        XCTAssertEqual(deleted.deletions, 1)
        let added = try reader.snapshot(path: "new folder/中文 file.ts", state: state, compare: true)
        XCTAssertEqual(added.before, "")
        XCTAssertEqual(added.additions, 1)
    }

    func testUnbornRepositoryAndBinaryPreview() throws {
        try write("first.ts", "const first = true;\n")
        try Data([0, 1, 2, 3]).write(to: folder.appendingPathComponent("binary.bin"))
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        XCTAssertFalse(state.hasHead)
        XCTAssertEqual(state.changes.count, 2)
        XCTAssertEqual(try reader.snapshot(path: "first.ts", state: state, compare: true).additions, 1)
        XCTAssertTrue(try reader.snapshot(path: "binary.bin", state: state, compare: true).isBinary)
    }

    func testLiteralPathspecsAndEmptyFiles() throws {
        let name = "[special]: file.ts"
        try write(name, "before\n")
        try write("empty.ts", "")
        try git(["add", "."])
        try git(["commit", "-qm", "initial"])
        try write(name, "after\n")
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        let snapshot = try reader.snapshot(path: name, state: state, compare: true)
        XCTAssertEqual(snapshot.before, "before\n")
        XCTAssertEqual(snapshot.after, "after\n")
        XCTAssertEqual(try reader.snapshot(path: "empty.ts", state: state, compare: true).rows, [])
    }

    func testPathTraversalAndAncestorSymlinkAreRejected() throws {
        let reader = try WorkspaceReader(folder: folder)
        XCTAssertThrowsError(try reader.files.safeURL("../outside"))
        XCTAssertThrowsError(try reader.files.safeURL("/etc/passwd"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("outside"), withDestinationURL: folder.deletingLastPathComponent())
        XCTAssertThrowsError(try reader.files.safeURL("outside/something"))
    }

    func testRegularFolderWorksWithoutGit() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".git"))
        try write("nested/main.ts", "let count = 0;\n")
        try write("node_modules/ignored.ts", "ignored\n")
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        XCTAssertFalse(state.isGit)
        XCTAssertEqual(state.files, ["nested/main.ts"])
        XCTAssertEqual(try reader.snapshot(path: "nested/main.ts", state: state, compare: false).after, "let count = 0;\n")
    }

    func testStagedAndUnstagedVersionsRemainIndependentWhenChangesCancel() throws {
        try write("src/version.ts", "export const version = 1;\n")
        try write("src/cancel.ts", "original\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write("src/version.ts", "export const version = 2;\n")
        try write("src/cancel.ts", "staged\n")
        try git(["add", "."])
        try write("src/version.ts", "export const version = 3;\n")
        try write("src/cancel.ts", "original\n")
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        XCTAssertEqual(state.changes.count, 4)
        for path in ["src/version.ts", "src/cancel.ts"] {
            XCTAssertEqual(Set(state.changes.filter { $0.path == path }.map(\.comparison)), [.staged, .unstaged])
        }
        let staged = try reader.snapshot(path: "src/version.ts", state: state, compare: true, comparison: .staged)
        let unstaged = try reader.snapshot(path: "src/version.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(staged.before, "export const version = 1;\n")
        XCTAssertEqual(staged.after, "export const version = 2;\n")
        XCTAssertEqual(unstaged.before, staged.after)
        XCTAssertEqual(unstaged.after, "export const version = 3;\n")
        let canceled = try reader.snapshot(path: "src/cancel.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(canceled.before, "staged\n")
        XCTAssertEqual(canceled.after, "original\n")
    }

    func testStagedRenameAndDeletionUseIndexInsteadOfDisk() throws {
        try write("old.ts", "original name\n")
        try write("deleted.ts", "committed content\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try git(["mv", "old.ts", "new.ts"])
        try git(["rm", "deleted.ts"])
        try write("new.ts", "working edit\n")
        try write("deleted.ts", "recreated untracked content\n")
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        let rename = try XCTUnwrap(state.changes.first { $0.path == "new.ts" && $0.comparison == .staged })
        XCTAssertEqual(rename.originalPath, "old.ts")
        let staged = try reader.snapshot(path: "new.ts", state: state, compare: true, comparison: .staged)
        XCTAssertEqual(staged.before, "original name\n")
        XCTAssertEqual(staged.after, "original name\n")
        let unstaged = try reader.snapshot(path: "new.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(unstaged.before, staged.after)
        XCTAssertEqual(unstaged.after, "working edit\n")
        let deleted = try reader.snapshot(path: "deleted.ts", state: state, compare: true, comparison: .staged)
        XCTAssertEqual(deleted.before, "committed content\n")
        XCTAssertEqual(deleted.after, "")
        let recreated = try reader.snapshot(path: "deleted.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(recreated.before, "")
        XCTAssertEqual(recreated.after, "recreated untracked content\n")
    }

    func testUnbornRepositorySeparatesIndexAndWorkingCopy() throws {
        try write("first.ts", "staged first version\n")
        try git(["add", "."])
        try write("first.ts", "unstaged second version\n")
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        XCTAssertFalse(state.hasHead)
        XCTAssertEqual(state.changes.count, 2)
        let staged = try reader.snapshot(path: "first.ts", state: state, compare: true, comparison: .staged)
        let unstaged = try reader.snapshot(path: "first.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(staged.before, "")
        XCTAssertEqual(staged.after, "staged first version\n")
        XCTAssertEqual(unstaged.before, staged.after)
        XCTAssertEqual(unstaged.after, "unstaged second version\n")
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", folder.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw GitError.command("Fixture command failed: \(arguments)") }
    }
}
