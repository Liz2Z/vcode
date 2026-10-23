import Foundation

// A composed read model: disk supplies browsing paths; Git supplies repository state.
struct WorkspaceState {
    let root: URL
    let files: [String]
    let git: GitStatus?
    let project: GitProject?
    let fileIdentities: [String: AnyHashable]

    init(root: URL, files: [String], git: GitStatus?, project: GitProject? = nil, fileIdentities: [String: AnyHashable] = [:]) {
        self.root = root; self.files = files; self.git = git; self.project = project
        self.fileIdentities = fileIdentities
    }

    var branch: String { git?.branch ?? "Folder" }
    var changes: [GitChange] { git?.changes ?? [] }
    var isGit: Bool { git != nil }
    var hasHead: Bool { git?.hasHead == true }

    func renames(from previous: WorkspaceState) -> [String: String] {
        guard root == previous.root else { return [:] }
        let currentPaths = Set(files)
        let byIdentity = Dictionary(grouping: fileIdentities.keys, by: { fileIdentities[$0]! })
        var result: [String: String] = [:]
        for (path, identity) in previous.fileIdentities where !currentPaths.contains(path) {
            // Hard links are ambiguous; never silently choose one of several targets.
            if let candidates = byIdentity[identity], candidates.count == 1 { result[path] = candidates[0] }
        }
        for change in changes where change.kind == .renamed {
            if let original = change.originalPath, !currentPaths.contains(original), currentPaths.contains(change.path) { result[original] = change.path }
        }
        return result
    }
}
