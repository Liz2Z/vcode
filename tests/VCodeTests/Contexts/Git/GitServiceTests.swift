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

    func testIgnoreRulesFilterDiskCandidatesAndPreserveTrackedExceptions() throws {
        let ignored = "hidden/[special]: 中文\tfile\n.ts"
        let tracked = "hidden/tracked.ts"
        try write(".gitignore", "hidden/\n")
        try write(ignored, "ignored\n")
        try write(tracked, "tracked despite ignore rule\n")
        try write("src/visible.ts", "visible\n")
        try git(["add", "-f", "--", tracked])
        let service = GitService(root: folder)
        XCTAssertEqual(try service.ignoredPaths(), [ignored])
        let state = try WorkspaceReader(folder: folder).load()
        XCTAssertEqual(Set(state.files), [".gitignore", ignored, tracked, "src/visible.ts"])
        XCTAssertEqual(Set(state.searchableFiles), [".gitignore", tracked, "src/visible.ts"])
    }

    func testStatusIncludesBranchMetadataForInitialUnicodeAndDetachedStates() throws {
        let service = GitService(root: folder)
        let initial = try XCTUnwrap(service.status())
        XCTAssertFalse(initial.hasHead)
        XCTAssertEqual(initial.branch, "main")
        try write("file.ts", "first\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try git(["switch", "-qc", "feature/中文"])
        XCTAssertEqual(try service.status()?.branch, "feature/中文")
        try git(["switch", "-q", "--detach"])
        let detached = try XCTUnwrap(service.status())
        XCTAssertTrue(detached.hasHead)
        XCTAssertTrue(detached.branch.allSatisfy { $0.isHexDigit })
        XCTAssertGreaterThanOrEqual(detached.branch.count, 4)
    }

    func testObjectLookupPreservesSizeLimitsEmptyAndMissingFiles() throws {
        try write("large\nfile.ts", "123456789\n")
        try write("empty.ts", "")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        let service = GitService(root: folder)
        for revision in [GitRevision.head, .index] {
            XCTAssertThrowsError(try service.content(at: revision, path: "large\nfile.ts", maximumByteCount: 3))
            XCTAssertEqual(try service.content(at: revision, path: "large\nfile.ts", maximumByteCount: 20), Data("123456789\n".utf8))
            XCTAssertEqual(try service.content(at: revision, path: "empty.ts", maximumByteCount: 3), Data())
            XCTAssertEqual(try service.content(at: revision, path: "missing\nfile.ts", maximumByteCount: 3), Data())
        }
    }

    func testUnmergedStatusRemainsAConflictWithNoStageZeroContent() throws {
        try write("conflict.ts", "initial\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try git(["switch", "-qc", "feature"])
        try write("conflict.ts", "feature\n"); try git(["commit", "-qam", "feature"])
        try git(["switch", "-q", "main"])
        try write("conflict.ts", "main\n"); try git(["commit", "-qam", "main"])
        XCTAssertThrowsError(try git(["merge", "--no-edit", "feature"]))
        let service = GitService(root: folder)
        let status = try XCTUnwrap(service.status())
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.changes, [GitChange(path: "conflict.ts", kind: .conflict, comparison: .unstaged)])
        XCTAssertEqual(try service.content(at: .index, path: "conflict.ts", maximumByteCount: 1024), Data())
        let reader = try WorkspaceReader(folder: folder)
        let snapshot = try reader.snapshot(path: "conflict.ts", state: reader.load(), compare: true, comparison: .unstaged)
        XCTAssertTrue(snapshot.message?.contains("Unmerged") == true)
    }

    func testStageAndUnstageFilePreserveWorkingCopyAndOtherChanges() throws {
        try write("file.ts", "head\n"); try write("other.ts", "head\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write("file.ts", "index\n"); try git(["add", "file.ts"])
        try write("file.ts", "working\n"); try write("other.ts", "untouched\n")
        let service = GitService(root: folder)
        try service.updateIndex(.stage, target: .file("file.ts"))
        XCTAssertEqual(try service.content(at: .index, path: "file.ts", maximumByteCount: 1024), Data("working\n".utf8))
        XCTAssertFalse(try XCTUnwrap(service.status()).changes.contains { $0.path == "file.ts" && $0.comparison == .unstaged })
        try service.updateIndex(.unstage, target: .file("file.ts"))
        XCTAssertEqual(try service.content(at: .index, path: "file.ts", maximumByteCount: 1024), Data("head\n".utf8))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("file.ts")), "working\n")
        XCTAssertEqual(try service.content(at: .index, path: "other.ts", maximumByteCount: 1024), Data("head\n".utf8))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("other.ts")), "untouched\n")
    }

    func testFolderStagesNestedAdditionsDeletionsAndDoesNotMatchSiblingPrefix() throws {
        try write("src/change.ts", "head\n"); try write("src/delete.ts", "delete\n"); try write("src2/other.ts", "head\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write("src/change.ts", "working\n"); try write("src/deep/new.ts", "new\n")
        try FileManager.default.removeItem(at: folder.appendingPathComponent("src/delete.ts"))
        try write("src2/other.ts", "keep unstaged\n")
        let service = GitService(root: folder)
        try service.updateIndex(.stage, target: .directory("src"))
        let changes = try XCTUnwrap(service.status()).changes
        XCTAssertEqual(Set(changes.filter { $0.comparison == .staged }.map(\.path)), ["src/change.ts", "src/delete.ts", "src/deep/new.ts"])
        XCTAssertEqual(changes.filter { $0.comparison == .unstaged }.map(\.path), ["src2/other.ts"])
        try service.updateIndex(.unstage, target: .directory("src"))
        XCTAssertFalse(try XCTUnwrap(service.status()).changes.contains { $0.comparison == .staged })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("src/delete.ts").path))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("src/deep/new.ts")), "new\n")
    }

    func testUnstageOnUnbornBranchKeepsNewFileEvenWhenWorkingContentDiffers() throws {
        let service = GitService(root: folder)
        try write("new.ts", "staged\n")
        try service.updateIndex(.stage, target: .file("new.ts"))
        try write("new.ts", "working changed again\n")
        try service.updateIndex(.unstage, target: .file("new.ts"))
        let status = try XCTUnwrap(service.status())
        XCTAssertFalse(status.hasHead)
        XCTAssertEqual(status.changes, [GitChange(path: "new.ts", kind: .untracked)])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("new.ts")), "working changed again\n")
    }

    func testIndexActionsUseLiteralNulDelimitedPathsAndRejectInvalidOrStaleTargets() throws {
        let paths = ["src/:(glob)*.ts", "src/[abc] 中文\tline\n.ts", "--option.ts"]
        for path in paths { try write(path, "head\n") }
        try write("src/victim.ts", "head\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        for path in paths { try write(path, "edit\n") }
        try write("src/victim.ts", "other edit\n")
        let service = GitService(root: folder)
        for path in paths {
            try service.updateIndex(.stage, target: .file(path))
            XCTAssertEqual(try service.content(at: .index, path: path, maximumByteCount: 1024), Data("edit\n".utf8))
            try service.updateIndex(.unstage, target: .file(path))
            XCTAssertEqual(try service.content(at: .index, path: path, maximumByteCount: 1024), Data("head\n".utf8))
        }
        for invalid in ["", "/outside", "../outside", "src/../victim.ts", "src//victim.ts", "src\0bad"] {
            XCTAssertThrowsError(try service.updateIndex(.stage, target: .file(invalid)))
        }
        XCTAssertThrowsError(try service.updateIndex(.unstage, target: .file("src/victim.ts")))
        XCTAssertFalse(try XCTUnwrap(service.status()).changes.contains { $0.comparison == .staged })
    }

    func testUnstageRenameRestoresBothIndexPathsAcrossFolderBoundary() throws {
        try write("old/location.ts", "rename contents\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("new"), withIntermediateDirectories: true)
        try git(["mv", "old/location.ts", "new/location.ts"])
        let service = GitService(root: folder)
        XCTAssertEqual(try XCTUnwrap(service.status()).changes.first?.kind, .renamed)
        try service.updateIndex(.unstage, target: .directory("new"))
        XCTAssertEqual(try service.content(at: .index, path: "old/location.ts", maximumByteCount: 1024), Data("rename contents\n".utf8))
        XCTAssertEqual(try service.content(at: .index, path: "new/location.ts", maximumByteCount: 1024), Data())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("old/location.ts").path))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("new/location.ts")), "rename contents\n")
        XCTAssertFalse(try XCTUnwrap(service.status()).changes.contains { $0.comparison == .staged })
    }

    func testStageAllAndUnstageAllPreserveWorkingContentsAndResolveCurrentCategory() throws {
        try write("a.ts", "head\n"); try write("b.ts", "head\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write("a.ts", "staged\n"); try git(["add", "a.ts"])
        try write("a.ts", "working a\n"); try write("b.ts", "working b\n")
        let service = GitService(root: folder)
        try service.updateIndex(.stage, target: .all)
        XCTAssertEqual(try service.content(at: .index, path: "a.ts", maximumByteCount: 1024), Data("working a\n".utf8))
        XCTAssertEqual(try service.content(at: .index, path: "b.ts", maximumByteCount: 1024), Data("working b\n".utf8))
        XCTAssertTrue(try XCTUnwrap(service.status()).changes.allSatisfy { $0.comparison == .staged })
        try write("b.ts", "another working edit\n")
        try service.updateIndex(.unstage, target: .all)
        XCTAssertTrue(try XCTUnwrap(service.status()).changes.allSatisfy { $0.comparison == .unstaged })
        XCTAssertEqual(try service.content(at: .index, path: "a.ts", maximumByteCount: 1024), Data("head\n".utf8))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.ts")), "working a\n")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("b.ts")), "another working edit\n")
        XCTAssertThrowsError(try service.updateIndex(.unstage, target: .all))
    }

    func testUnstageDetectedCopyDoesNotResetIndependentStagedSourceEdits() throws {
        let original = (0..<100).map { "line \($0)\n" }.joined()
        try git(["config", "status.renames", "copies"])
        try write("source.ts", original)
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write("copy.ts", original); try write("source.ts", original + "source staged edit\n")
        try git(["add", "."])
        let service = GitService(root: folder)
        XCTAssertEqual(try service.status()?.changes.first { $0.path == "copy.ts" }?.originalPath, "source.ts")
        try service.updateIndex(.unstage, target: .file("copy.ts"))
        XCTAssertEqual(try service.content(at: .index, path: "source.ts", maximumByteCount: 4096), Data((original + "source staged edit\n").utf8))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("copy.ts")), original)
    }

    func testLockedIndexFailsWithoutTouchingWorkingCopyAndLinkedWorktreeUsesOwnIndex() throws {
        try write("file.ts", "head\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        let linked = folder.deletingLastPathComponent().appendingPathComponent("linked-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: linked) }
        try git(["worktree", "add", "-qb", "linked", linked.path])
        try "linked edit\n".write(to: linked.appendingPathComponent("file.ts"), atomically: true, encoding: .utf8)
        try GitService(root: linked).updateIndex(.stage, target: .file("file.ts"))
        let service = GitService(root: folder)
        XCTAssertEqual(try service.content(at: .index, path: "file.ts", maximumByteCount: 1024), Data("head\n".utf8))
        XCTAssertEqual(try GitService(root: linked).content(at: .index, path: "file.ts", maximumByteCount: 1024), Data("linked edit\n".utf8))
        try write("file.ts", "local edit\n")
        let lock = folder.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        XCTAssertThrowsError(try service.updateIndex(.stage, target: .file("file.ts")))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("file.ts")), "local edit\n")
        try FileManager.default.removeItem(at: lock)
        try service.updateIndex(.stage, target: .file("file.ts"))
        XCTAssertEqual(try service.content(at: .index, path: "file.ts", maximumByteCount: 1024), Data("local edit\n".utf8))
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
