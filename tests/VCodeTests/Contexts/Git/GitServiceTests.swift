import XCTest
@testable import VCode

final class GitServiceTests: XCTestCase {
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

    func testBranchSwitchPreservesCompatibleEditsAndRejectsConflictingEdits() throws {
        try write("shared.ts", "export const version = 1;\n")
        try write("local.ts", "original\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try git(["switch", "-qc", "feature"])
        try write("shared.ts", "export const version = 2;\n")
        try git(["commit", "-qam", "feature change"])
        try git(["switch", "-q", "main"])
        try write("local.ts", "compatible local edit\n")
        try write("untracked.ts", "keep me\n")
        let repository = GitService(root: folder)
        let switched = try repository.activate(.branch("feature"))
        XCTAssertEqual(try GitService(root: switched).status()?.branch, "feature")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("local.ts"), encoding: .utf8), "compatible local edit\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("untracked.ts").path))
        try write("shared.ts", "keep this staged edit\n")
        try git(["add", "shared.ts"])
        XCTAssertThrowsError(try repository.activate(.branch("main")))
        XCTAssertEqual(try repository.status()?.branch, "feature")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("shared.ts"), encoding: .utf8), "keep this staged edit\n")
        XCTAssertThrowsError(try repository.activate(.branch("--discard-changes")))
    }

    func testBranchInAnotherWorktreeOpensThatWorktreeWithIndependentChanges() throws {
        try write("main.ts", "initial\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        let linked = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + " linked\nworktree")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git(["worktree", "add", "-qb", "feature/测试", linked.path])
        try write("main.ts", "primary local edit\n")
        try "linked local edit\n".write(to: linked.appendingPathComponent("main.ts"), atomically: true, encoding: .utf8)
        let repository = GitService(root: folder)
        let options = try repository.destinations()
        XCTAssertEqual(options.branches.map(\.name).sorted(), ["feature/测试", "main"])
        XCTAssertEqual(options.worktrees.count, 2)
        let target = try XCTUnwrap(options.worktrees.first { $0.branch == "feature/测试" })
        XCTAssertEqual(target.root.path, linked.resolvingSymlinksInPath().path)
        let opened = try repository.activate(.branch("feature/测试"))
        XCTAssertEqual(opened, target.root)
        XCTAssertEqual(try GitService(root: opened).status()?.branch, "feature/测试")
        XCTAssertEqual(try repository.status()?.branch, "main")
        XCTAssertEqual(try String(contentsOf: opened.appendingPathComponent("main.ts"), encoding: .utf8), "linked local edit\n")
        let original = try GitService(root: opened).headContent(path: "main.ts", maximumByteCount: 1024)
        XCTAssertEqual(String(decoding: original, as: UTF8.self), "initial\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("main.ts"), encoding: .utf8), "primary local edit\n")
        XCTAssertEqual(try GitService(root: opened).activate(.worktree(repository.root)), repository.root)
    }

    func testDetachedAndMissingWorktreeStates() throws {
        try write("main.ts", "initial\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        let linked = folder.appendingPathExtension("detached")
        defer { try? FileManager.default.removeItem(at: linked) }
        try git(["worktree", "add", "-q", "--detach", linked.path, "HEAD"])
        let repository = GitService(root: folder)
        let target = try XCTUnwrap(repository.destinations().worktrees.first { $0.root != repository.root })
        XCTAssertNil(target.branch)
        XCTAssertTrue(target.isAvailable)
        XCTAssertFalse(target.head.isEmpty)
        XCTAssertNil(try GitService(root: repository.activate(.worktree(target.root))).destinations().currentBranch)
        try FileManager.default.removeItem(at: linked)
        let missing = try XCTUnwrap(repository.destinations().worktrees.first { $0.root == target.root })
        XCTAssertFalse(missing.isAvailable)
        XCTAssertThrowsError(try repository.activate(.worktree(target.root)))
    }

    func testStatusAndIndexContentPreserveLiteralUnicodePaths() throws {
        let path = "src/[special]: 中文\tfile\n.ts"
        try write(path, "committed\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write(path, "staged\n")
        try git(["add", "--", path])
        try write(path, "working\n")
        let service = GitService(root: folder)
        let status = try XCTUnwrap(service.status())
        XCTAssertEqual(status.changes.map(\.path), [path, path])
        XCTAssertEqual(Set(status.changes.map(\.comparison)), [.staged, .unstaged])
        let data = try service.content(at: .index, path: path, maximumByteCount: 1024)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "staged\n")
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
