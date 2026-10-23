import Foundation

struct ExternalOpenTarget {
    let root: URL
    let file: URL?

    func relativePath(in root: URL) -> String? {
        guard let file else { return nil }
        let prefix = root.path == "/" ? "/" : root.path + "/"
        guard file.path.hasPrefix(prefix) else { return nil }
        return String(file.path.dropFirst(prefix.count))
    }
}

/// Resolve document events off the main thread, reusing Git's worktree discovery.
enum ExternalOpenResolver {
    enum OpenError: LocalizedError {
        case outsideGitRepository
        var errorDescription: String? { "This file must be inside a Git repository or worktree." }
    }

    static func resolve(_ url: URL) throws -> ExternalOpenTarget {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true { return ExternalOpenTarget(root: url, file: nil) }
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
        guard let root = GitService(root: url.deletingLastPathComponent()).repositoryRoot() else {
            throw OpenError.outsideGitRepository
        }
        return ExternalOpenTarget(root: root, file: url)
    }
}
