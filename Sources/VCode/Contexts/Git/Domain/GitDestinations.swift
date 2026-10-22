import Foundation

struct GitProject {
    let commonDirectory: URL
    let primaryRoot: URL
}

struct GitWorktree: Equatable {
    let root: URL
    let branch: String?
    let head: String
    let isBare: Bool
    let isAvailable: Bool
    let note: String?
}

struct GitBranch: Equatable {
    let name: String
    let worktree: URL?
}

struct GitDestinations {
    let root: URL
    let currentBranch: String?
    let branches: [GitBranch]
    let worktrees: [GitWorktree]
}

enum GitDestination: Equatable {
    case branch(String)
    case worktree(URL)
}
