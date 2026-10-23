import Foundation

struct WindowPlacement: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

final class WorkspaceHistoryStore {
    private struct StoredState: Codable {
        var version = 1
        var entries: [RecentWorkspace] = []
        var lastFolder: URL?
        var window: WindowPlacement?
        var recentFiles: [String: [String]]?
        var readingSessions: [String: WorkspaceReadingSession]?
    }
    let file: URL
    private var stored = StoredState()
    private var unreadable = false
    private(set) var persistenceError: String?
    var onError: ((String) -> Void)?
    var entries: [RecentWorkspace] { stored.entries }
    var lastFolder: URL? { stored.lastFolder }
    var windowPlacement: WindowPlacement? { stored.window }
    static let limit = 40

    init(directory: URL = XDGDirectories().state, legacyDefaults: UserDefaults? = .standard) {
        file = directory.appendingPathComponent("workspace.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let decoded = try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: file))
                guard decoded.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                stored = decoded
            } catch {
                // Keep an invalid/unreadable file intact instead of overwriting it.
                persistenceError = "Could not read workspace history: " + error.localizedDescription
                unreadable = true
            }
        } else if let legacyDefaults {
            stored.entries = legacyDefaults.data(forKey: "recentWorkspaces.v1").flatMap { try? JSONDecoder().decode([RecentWorkspace].self, from: $0) } ?? []
            stored.lastFolder = legacyDefaults.string(forKey: "lastFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let frame = legacyDefaults.string(forKey: "NSWindow Frame VCodeWorkspace") {
                let values = frame.split(separator: " ").compactMap { Double($0) }
                if values.count >= 4 { stored.window = WindowPlacement(x: values[0], y: values[1], width: values[2], height: values[3]) }
            }
            if !stored.entries.isEmpty || stored.lastFolder != nil || stored.window != nil {
                if persist() {
                    for key in ["recentWorkspaces.v1", "lastFolder", "NSWindow Frame VCodeWorkspace"] { legacyDefaults.removeObject(forKey: key) }
                }
            }
        }
        var paths = Set<String>()
        stored.entries = Array(stored.entries.sorted { $0.openedAt > $1.openedAt }.filter {
            $0.root.isFileURL && $0.projectRoot.isFileURL && paths.insert($0.root.standardizedFileURL.path).inserted
        }.prefix(Self.limit))
    }

    func record(_ state: WorkspaceState, at date: Date = Date()) {
        stored.entries.removeAll { $0.root == state.root }
        stored.entries.insert(RecentWorkspace(state: state, openedAt: date), at: 0)
        stored.entries = Array(stored.entries.prefix(Self.limit))
        stored.lastFolder = state.root
        persist()
    }

    // Refresh branch metadata without making background refreshes look like visits.
    func update(_ state: WorkspaceState) {
        guard let index = stored.entries.firstIndex(where: { $0.root == state.root }) else { return }
        let updated = RecentWorkspace(state: state, openedAt: stored.entries[index].openedAt)
        guard stored.entries[index] != updated else { return }
        stored.entries[index] = updated
        persist()
    }

    func removeRecent(_ root: URL) {
        let path = root.standardizedFileURL.path
        guard stored.entries.contains(where: { $0.root.standardizedFileURL.path == path }) else { return }
        stored.entries.removeAll { $0.root.standardizedFileURL.path == path }
        persist()
    }

    func clearRecents() {
        guard !stored.entries.isEmpty else { return }
        stored.entries.removeAll()
        persist()
    }

    func saveWindow(_ placement: WindowPlacement) {
        guard stored.window != placement else { return }
        stored.window = placement
        persist()
    }

    func recentFiles(in root: URL) -> [String] { stored.recentFiles?[root.standardizedFileURL.path] ?? [] }

    func recordFile(_ path: String, in root: URL) {
        let key = root.standardizedFileURL.path
        var recent = stored.recentFiles ?? [:]
        if recent[key]?.first == path { return }
        var files = recent[key] ?? []; files.removeAll { $0 == path }; files.insert(path, at: 0)
        recent[key] = Array(files.prefix(100))
        let availableRoots = Set(stored.entries.map { $0.root.standardizedFileURL.path } + [key])
        stored.recentFiles = recent.filter { availableRoots.contains($0.key) }
        persist()
    }

    func renameFiles(_ renames: [String: String], in root: URL) {
        guard !renames.isEmpty else { return }
        let key = root.standardizedFileURL.path
        guard let previous = stored.recentFiles?[key] else { return }
        var seen = Set<String>()
        let next = previous.map { renames[$0] ?? $0 }.filter { seen.insert($0).inserted }
        if previous != next { stored.recentFiles?[key] = next; persist() }
    }

    func readingSession(in root: URL) -> WorkspaceReadingSession? {
        stored.readingSessions?[root.standardizedFileURL.path]
    }

    func saveReadingSession(_ session: WorkspaceReadingSession, in root: URL) {
        let key = root.standardizedFileURL.path
        guard stored.readingSessions?[key] != session else { return }
        var sessions = stored.readingSessions ?? [:]
        sessions[key] = session
        let roots = Set(stored.entries.map { $0.root.standardizedFileURL.path } + [key])
        stored.readingSessions = sessions.filter { roots.contains($0.key) }
        persist()
    }

    func isAvailable(_ root: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &directory) && directory.boolValue
    }

    @discardableResult private func persist() -> Bool {
        guard !unreadable else { onError?(persistenceError ?? "Could not read workspace history"); return false }
        do {
            let directory = file.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(stored).write(to: file, options: .atomic)
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Could not save workspace history: " + error.localizedDescription
            onError?(persistenceError!)
            return false
        }
    }
}
