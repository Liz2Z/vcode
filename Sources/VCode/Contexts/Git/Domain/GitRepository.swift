import Foundation

// One Git port shared by changes, branch selection and worktree selection.
protocol GitRepository {
    var root: URL { get }
    func repositoryRoot() -> URL?
    func projectIdentity() throws -> GitProject
    func status() throws -> GitStatus?
    func ignoredPaths() throws -> Set<String>
    func destinations() throws -> GitDestinations
    func updateIndex(_ action: GitIndexAction, paths: [String], hasHead: Bool) throws
    func switchBranch(_ name: String) throws
    func validatedWorktreeRoot(_ root: URL) throws -> URL
    func content(at revision: GitRevision, path: String, maximumByteCount: Int) throws -> Data
    func patch(before: Data, after: Data) throws -> String
}
