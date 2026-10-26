import Foundation

// Coordinates independent file browsing and Git capabilities for the reading UI.
final class WorkspaceReader {
    let git: GitService
    let files: FileBrowser
    private let project: GitProject?
    private var lastComparison: FileSnapshot?
    var root: URL { files.root }

    init(folder: URL) throws {
        let initial = try FileBrowser(root: folder)
        let discovered = GitService(root: initial.root).repositoryRoot() ?? initial.root
        files = try FileBrowser(root: discovered)
        git = GitService(root: files.root)
        project = try? git.projectIdentity()
    }

    func load() throws -> WorkspaceState {
        let status = try git.status()
        let ignored = status == nil ? Set<String>() : try git.ignoredPaths()
        let listing = try files.listing(excluding: ignored)
        return WorkspaceState(root: root, files: listing.paths, git: status, project: project, fileIdentities: listing.identities,
                              searchableFiles: listing.searchablePaths, directories: listing.directories, deferredDirectories: listing.deferredDirectories)
    }

    func snapshot(path: String, state: WorkspaceState, compare: Bool, comparison: GitComparison = .workingTree) throws -> FileSnapshot {
        let change = state.changes.first { $0.path == path && $0.comparison == comparison }
        let oldPath = change?.originalPath ?? path
        let scope = compare && state.isGit ? comparison : nil
        if scope == nil && !files.exists(path) {
            return FileSnapshot(path: path, before: "", after: "", rows: [], message: "File deleted or moved · Waiting for this path to become available again.", isBinary: false)
        }
        if scope == .unstaged && change?.kind == .conflict {
            return FileSnapshot(path: path, before: "", after: "", rows: [], message: "Unmerged file · The index contains multiple conflict versions. Resolve the conflict to compare changes.", isBinary: false, comparison: scope)
        }
        let content: SourceContent
        if scope == .staged {
            content = SourceContent(data: try git.content(at: .index, path: path, maximumByteCount: FileSnapshot.maximumByteCount), message: nil)
        } else {
            content = try files.read(path, maximumByteCount: FileSnapshot.maximumByteCount)
        }
        if let note = content.message {
            return FileSnapshot(path: path, before: "", after: "", rows: [], message: note, isBinary: false, comparison: scope)
        }
        let original: SourceContent
        if scope == .unstaged && change?.kind != .conflict {
            original = SourceContent(data: try git.content(at: .index, path: oldPath, maximumByteCount: FileSnapshot.maximumByteCount), message: nil)
        } else if scope != nil && state.hasHead {
            original = SourceContent(data: try git.headContent(path: oldPath, maximumByteCount: FileSnapshot.maximumByteCount), message: nil)
        } else { original = SourceContent(data: Data(), message: nil) }
        if content.isBinary || original.isBinary {
            return FileSnapshot(path: path, before: "", after: "", rows: [], message: "Binary file · Preview unavailable", isBinary: true, comparison: scope)
        }
        let before = String(decoding: original.data, as: UTF8.self)
        let after = String(decoding: content.data, as: UTF8.self)
        guard compare else { return FileSnapshot(path: path, before: "", after: after, rows: [], message: nil, isBinary: false) }
        if let cached = lastComparison, cached.path == path, cached.comparison == scope, cached.before == before, cached.after == after { return cached }
        let patch = try git.patch(before: original.data, after: content.data)
        let rows = try Diff.align(before: before, after: after, patch: patch)
        let snapshot = FileSnapshot(path: path, before: before, after: after, rows: rows, message: nil, isBinary: false, comparison: scope)
        // One bounded entry prevents unchanged refreshes from launching git diff
        // again. Actual content is always re-read, so no timestamp assumptions.
        lastComparison = original.data.count + content.data.count <= 1_048_576 ? snapshot : nil
        return snapshot
    }
}
