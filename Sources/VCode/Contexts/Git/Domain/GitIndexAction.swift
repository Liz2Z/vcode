import Foundation

enum GitIndexAction {
    case stage, unstage
    var comparison: GitComparison { self == .stage ? .unstaged : .staged }
    var title: String { self == .stage ? "Stage Changes" : "Unstage Changes" }
    var allTitle: String { self == .stage ? "Stage All Changes" : "Unstage All Changes" }
    var symbol: String { self == .stage ? "plus" : "minus" }
}

enum GitChangeTarget {
    case all
    case file(String)
    case directory(String)

    var path: String {
        switch self { case .all: return ""; case .file(let path), .directory(let path): return path }
    }
    func contains(_ path: String) -> Bool {
        switch self {
        case .all: return true
        case .file(let file): return path == file
        case .directory(let folder): return path.hasPrefix(folder + "/")
        }
    }
    var isValid: Bool {
        if case .all = self { return true }
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}
