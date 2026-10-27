import Foundation

final class GitService {
    private let repository: any GitRepository
    var root: URL { repository.root }

    init(repository: any GitRepository) { self.repository = repository }
    convenience init(root: URL) { self.init(repository: GitCLI(root: root)) }

    func repositoryRoot() -> URL? { repository.repositoryRoot() }
    func projectIdentity() throws -> GitProject { try repository.projectIdentity() }
    func status() throws -> GitStatus? { try repository.status() }
    func ignoredPaths() throws -> Set<String> { try repository.ignoredPaths() }
    func destinations() throws -> GitDestinations { try repository.destinations() }
    func headContent(path: String, maximumByteCount: Int) throws -> Data {
        try repository.content(at: .head, path: path, maximumByteCount: maximumByteCount)
    }
    func content(at revision: GitRevision, path: String, maximumByteCount: Int) throws -> Data {
        try repository.content(at: revision, path: path, maximumByteCount: maximumByteCount)
    }
    func patch(before: Data, after: Data) throws -> String { try repository.patch(before: before, after: after) }

    /// Resolve the entire category from fresh Git status, independent of tree filtering or expansion.
    func updateIndex(_ action: GitIndexAction, target: GitChangeTarget) throws {
        guard target.isValid else { throw GitError.command("Invalid repository-relative change path.") }
        guard let status = try status() else { throw GitError.command("This folder is not a Git repository.") }
        let changes = status.changes.filter {
            $0.comparison == action.comparison && target.contains($0.path) && ProjectFileVisibility.isVisible($0.path)
        }
        guard !changes.isEmpty else { throw GitError.command("These changes are no longer available. Refresh the Changes list.") }
        // A rename is one operation even when its original path is outside the selected folder.
        let paths = Set(changes.flatMap { [$0.path] + ($0.kind == .renamed ? ($0.originalPath.map { [$0] } ?? []) : []) }).sorted()
        try repository.updateIndex(action, paths: paths, hasHead: status.hasHead)
    }

    // The domain owns branch occupancy and worktree availability rules; UI chooses a destination.
    func activate(_ destination: GitDestination) throws -> URL {
        let options = try destinations()
        switch destination {
        case .branch(let name):
            guard let branch = options.branches.first(where: { $0.name == name }) else {
                throw GitError.command("This local branch no longer exists.")
            }
            if let occupied = branch.worktree, occupied != root {
                return try activateWorktree(occupied, options: options)
            }
            try repository.switchBranch(name)
            return root
        case .worktree(let url): return try activateWorktree(url, options: options)
        }
    }

    private func activateWorktree(_ url: URL, options: GitDestinations) throws -> URL {
        guard let target = options.worktrees.first(where: { $0.root == url && $0.isAvailable }) else {
            throw GitError.command("This worktree is no longer available. Refresh the worktree list.")
        }
        return try repository.validatedWorktreeRoot(target.root)
    }
}
