import Foundation

struct FileTreeReadingState: Codable, Equatable {
    var expanded: [String]
    var collapsed: [String]
    var selection: String?
    var query: String
    var scrollOffset: Double
}

/// The store keys this by worktree root, not by a repository's shared Git directory.
struct WorkspaceReadingSession: Codable, Equatable {
    var groups: [EditorReadingSession]
    var activeGroup: Int
    var splitRatio: Double
    var sidebarWidth: Double
    var changesOnly: Bool
    var trees: [String: FileTreeReadingState]
}
