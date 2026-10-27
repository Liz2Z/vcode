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
        XCTAssertFalse(state.files.contains("remove.ts"), "Files must not include paths that only exist in the Git index")
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

    func testFileListRefreshUsesDiskWhileChangesRetainDeletedVersions() throws {
        try write("src/keep.ts", "keep\n")
        try write("gone/unstaged.ts", "unstaged deletion\n")
        try write("staged/deleted.ts", "staged deletion\n")
        try write("rename/old.ts", "renamed then deleted\n")
        try write(".gitignore", "ignored/\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        let reader = try WorkspaceReader(folder: folder)
        XCTAssertEqual(try reader.load().files.count, 5)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("gone/unstaged.ts"))
        try git(["rm", "staged/deleted.ts"])
        try git(["mv", "rename/old.ts", "rename/new.ts"])
        try FileManager.default.removeItem(at: folder.appendingPathComponent("rename/new.ts"))
        try write("new/中文 file.ts", "new\n")
        try write("ignored/hidden.ts", "ignored\n")

        let deleted = try reader.load()
        XCTAssertEqual(Set(deleted.files), [".gitignore", "src/keep.ts", "new/中文 file.ts"])
        XCTAssertEqual(Set(FileTreeIndex(paths: deleted.files).children(in: "").map(\.name)), [".gitignore", "src", "new"])
        XCTAssertTrue(deleted.changes.contains { $0.path == "gone/unstaged.ts" && $0.kind == .deleted && $0.comparison == .unstaged })
        XCTAssertTrue(deleted.changes.contains { $0.path == "staged/deleted.ts" && $0.kind == .deleted && $0.comparison == .staged })
        let snapshot = try reader.snapshot(path: "gone/unstaged.ts", state: deleted, compare: true, comparison: .unstaged)
        XCTAssertEqual(snapshot.before, "unstaged deletion\n")
        XCTAssertEqual(snapshot.after, "")

        // A staged deletion can coexist with a real, newly recreated file.
        try write("staged/deleted.ts", "recreated on disk\n")
        let recreated = try reader.load()
        XCTAssertTrue(recreated.files.contains("staged/deleted.ts"))
        XCTAssertTrue(recreated.changes.contains { $0.path == "staged/deleted.ts" && $0.kind == .deleted && $0.comparison == .staged })
        XCTAssertEqual(try reader.snapshot(path: "staged/deleted.ts", state: recreated, compare: false).after, "recreated on disk\n")
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

    func testIgnoredRegularFilesAndSymlinksDoNotSkipAdjacentDirectories() throws {
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".git"))
        try write("src/.DS_Store", "Finder metadata\n")
        try write("src/auth/request.ts", "export const request = true;\n")
        try write("src/biz-groups/index.ts", "export const group = true;\n")
        try write("src/shared/index.ts", "export const shared = true;\n")
        // Linked worktrees have a regular .git marker rather than a directory.
        try write(".git", "gitdir: /nonexistent/fixture\n")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("src/alias"), withDestinationURL: folder.appendingPathComponent("src/auth"))
        let paths = try FileBrowser(root: folder).list()
        XCTAssertEqual(Set(paths), ["src/alias", "src/auth/request.ts", "src/biz-groups/index.ts", "src/shared/index.ts"])
        XCTAssertFalse(paths.contains { $0.hasPrefix("src/alias/") }, "Directory links must not be traversed")
    }

    func testSystemMetadataStaysHiddenWhileSwapFilesRemainVisibleAndStageable() throws {
        let visible = [".env.local", ".gitignore", ".vscode/settings.json", "src/main.ts", "src/notes.swp.md",
                       "AGENTS.md.swp", ".draft.swo", ".draft.swn", "src/AGENTS.md.swp"]
        let artifacts = [".DS_Store", "._main.ts", "src/.DS_Store", ".AppleDouble/resource", "__MACOSX/resource", ".Spotlight-V100/index"]
        for path in visible + artifacts { try write(path, "initial\n") }
        try write(".gitignore", "cache/\n")
        try git(["add", "-f", "--"] + visible + artifacts)
        try git(["commit", "-qm", "tracked files and metadata"])
        for path in artifacts + ["src/main.ts", "AGENTS.md.swp"] { try write(path, "changed\n") }
        try write("cache/.DS_Store", "metadata\n")
        try write("cache/source.ts.swp", "swap\n")
        try write("cache/source.ts", "ignored but visible\n")
        let reader = try WorkspaceReader(folder: folder)
        var state = try reader.load()
        XCTAssertEqual(Set(state.files), Set(visible))
        XCTAssertEqual(Set(state.searchableFiles), Set(visible))
        XCTAssertEqual(Set(state.directories), [".vscode", "src", "cache"])
        XCTAssertEqual(Set(try reader.files.children(in: "src").map(\.name)), ["AGENTS.md.swp", "main.ts", "notes.swp.md"])
        XCTAssertEqual(Set(try reader.files.children(in: "cache").map(\.name)), ["source.ts", "source.ts.swp"])
        XCTAssertEqual(Set(state.changes.map(\.path)), ["AGENTS.md.swp", "src/main.ts"])
        XCTAssertTrue(state.git?.changes.contains { $0.path == ".DS_Store" } == true, "Raw Git status remains complete")
        try reader.git.updateIndex(.stage, target: .all)
        state = try reader.load()
        XCTAssertEqual(state.changes.map(\.comparison), [.staged, .staged])
        XCTAssertEqual(Set(state.git?.changes.filter { $0.comparison == .staged }.map(\.path) ?? []), ["AGENTS.md.swp", "src/main.ts"])
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(".DS_Store"), encoding: .utf8), "changed\n")
        // Unstaging visible files must not silently unstage hidden, preexisting index entries.
        try git(["add", "-f", ".DS_Store"])
        try reader.git.updateIndex(.unstage, target: .all)
        state = try reader.load()
        XCTAssertEqual(state.changes.map(\.comparison), [.unstaged, .unstaged])
        XCTAssertTrue(state.git?.changes.contains { $0.path == ".DS_Store" && $0.comparison == .staged } == true)
    }

    func testIgnoredSubtreesArePrunedWithoutHidingTrackedFilesOrNewIgnoreRules() throws {
        try write(".gitignore", "cache/\nsrc/generated/\n")
        try write("cache/untracked.ts", "ignored\n")
        try write("cache/nested/keep.ts", "tracked exception\n")
        try write("src/generated/ignored.ts", "ignored\n")
        try write("src/visible.ts", "visible\n")
        try git(["add", "-f", "cache/nested/keep.ts"])
        let reader = try WorkspaceReader(folder: folder)
        XCTAssertEqual(Set(try reader.load().searchableFiles), [".gitignore", "cache/nested/keep.ts", "src/visible.ts"])
        // Refresh must evaluate changed ignore rules rather than reuse old ones.
        try write(".gitignore", "cache/\n")
        XCTAssertEqual(Set(try reader.load().searchableFiles), [".gitignore", "cache/nested/keep.ts", "src/visible.ts", "src/generated/ignored.ts"])
    }

    func testRepeatedDiffReadsInvalidateOnActualSourceAndIndexContentChanges() throws {
        try write("sample.ts", "export const value = 1;\n")
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write("sample.ts", "export const value = 2;\n")
        let reader = try WorkspaceReader(folder: folder)
        let state = try reader.load()
        let first = try reader.snapshot(path: "sample.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(try reader.snapshot(path: "sample.ts", state: state, compare: true, comparison: .unstaged), first)
        try write("sample.ts", "export const value = 3;\n")
        let second = try reader.snapshot(path: "sample.ts", state: state, compare: true, comparison: .unstaged)
        XCTAssertEqual(second.after, "export const value = 3;\n")
        XCTAssertNotEqual(second, first)
        try git(["add", "sample.ts"])
        let staged = try reader.snapshot(path: "sample.ts", state: try reader.load(), compare: true, comparison: .staged)
        XCTAssertEqual(staged.before, first.before)
        XCTAssertEqual(staged.after, second.after)
        let clean = try reader.snapshot(path: "sample.ts", state: try reader.load(), compare: true, comparison: .unstaged)
        XCTAssertEqual(clean.before, clean.after)
        XCTAssertEqual(clean.additions, 0)
        XCTAssertEqual(clean.deletions, 0)
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
