import Foundation

enum GitChangeKind: String {
    case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "U", conflict = "!", typeChanged = "T"
}

enum GitComparison: String, CaseIterable {
    case staged, unstaged, workingTree
}

enum GitRevision { case head, index }

struct GitChange: Equatable {
    let path: String
    let originalPath: String?
    let kind: GitChangeKind
    let comparison: GitComparison

    init(path: String, originalPath: String? = nil, kind: GitChangeKind, comparison: GitComparison = .unstaged) {
        self.path = path
        self.originalPath = originalPath
        self.kind = kind
        self.comparison = comparison
    }
}

struct GitStatus {
    let root: URL
    let branch: String
    let files: [String]
    let changes: [GitChange]
    let hasHead: Bool
}
