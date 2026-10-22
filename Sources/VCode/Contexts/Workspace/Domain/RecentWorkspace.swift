import Foundation

struct RecentWorkspace: Codable, Equatable {
    let root: URL
    let projectID: String
    let projectRoot: URL
    let branch: String?
    let openedAt: Date

    init(state: WorkspaceState, openedAt: Date) {
        root = state.root
        projectID = state.project?.commonDirectory.path ?? state.root.path
        projectRoot = state.project?.primaryRoot ?? state.root
        branch = state.isGit ? state.branch : nil
        self.openedAt = openedAt
    }

    var projectName: String { projectRoot.lastPathComponent }
    var title: String { root.lastPathComponent + (branch.map { " · " + $0 } ?? " · Folder") }
}

struct RecentProject {
    let id: String
    let root: URL
    let workspaces: [RecentWorkspace]

    static func group(_ entries: [RecentWorkspace], matching query: String = "") -> [RecentProject] {
        let matching = entries.filter {
            query.isEmpty || ($0.projectName + " " + $0.title + " " + $0.root.path).localizedCaseInsensitiveContains(query)
        }.sorted { $0.openedAt > $1.openedAt }
        var order: [String] = []
        var grouped: [String: [RecentWorkspace]] = [:]
        for entry in matching {
            if grouped[entry.projectID] == nil { order.append(entry.projectID) }
            grouped[entry.projectID, default: []].append(entry)
        }
        return order.compactMap { id in
            guard let workspaces = grouped[id], let first = workspaces.first else { return nil }
            return RecentProject(id: id, root: first.projectRoot, workspaces: workspaces)
        }
    }
}
