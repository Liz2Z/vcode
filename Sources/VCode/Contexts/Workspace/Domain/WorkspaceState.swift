import Foundation

// A composed read model. Git remains the source of truth for all repository state.
struct WorkspaceState {
    let root: URL
    let files: [String]
    let git: GitStatus?
    let project: GitProject?

    init(root: URL, files: [String], git: GitStatus?, project: GitProject? = nil) {
        self.root = root; self.files = files; self.git = git; self.project = project
    }

    var branch: String { git?.branch ?? "Folder" }
    var changes: [GitChange] { git?.changes ?? [] }
    var isGit: Bool { git != nil }
    var hasHead: Bool { git?.hasHead == true }
}
