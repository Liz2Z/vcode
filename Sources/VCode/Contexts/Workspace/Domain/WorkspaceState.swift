import Foundation

// A composed read model: disk supplies browsing paths; Git supplies repository state.
struct WorkspaceState {
    let root: URL
    let files: [String]
    let git: GitStatus?
    let changes: [GitChange]
    let project: GitProject?
    let fileIdentities: [String: AnyHashable]
    let searchableFiles: [String]
    let directories: [String]
    let deferredDirectories: Set<String>
    let ignoredPaths: Set<String>

    init(root: URL, files: [String], git: GitStatus?, project: GitProject? = nil, fileIdentities: [String: AnyHashable] = [:],
         searchableFiles: [String]? = nil, directories: [String] = [], deferredDirectories: Set<String> = [], ignoredPaths: Set<String> = []) {
        self.root = root; self.files = files; self.git = git; self.project = project
        self.changes = git?.changes.filter { ProjectFileVisibility.isVisible($0.path) } ?? []
        self.fileIdentities = fileIdentities
        self.searchableFiles = searchableFiles ?? files
        self.directories = directories
        self.deferredDirectories = deferredDirectories
        self.ignoredPaths = ignoredPaths
    }

    var branch: String { git?.branch ?? "Folder" }
    var isGit: Bool { git != nil }
    var hasHead: Bool { git?.hasHead == true }

    func isGitIgnored(_ path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
            if ignoredPaths.contains(prefix) || ignoredPaths.contains(prefix + "/") { return true }
        }
        return false
    }

    func isDeferredDirectory(_ path: String) -> Bool {
        var prefix = ""
        for part in path.split(separator: "/") {
            prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
            if deferredDirectories.contains(prefix) { return true }
        }
        return false
    }

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
