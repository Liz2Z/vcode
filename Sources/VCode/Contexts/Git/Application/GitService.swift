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
