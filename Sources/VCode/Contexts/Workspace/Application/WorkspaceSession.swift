import Foundation

final class WorkspaceSession {
    private(set) var reader: WorkspaceReader?
    private(set) var state: WorkspaceState?
    var onOpen: ((WorkspaceState) -> Void)?
    var onRefresh: ((WorkspaceState) -> Void)?
    var onError: ((Error) -> Void)?
    private let queue = DispatchQueue(label: "vcode.workspace", qos: .userInitiated)
    private var watcher: FolderWatcher?
    private var generation = UUID()
    private let defaultDocumentScope = UUID()
    private var documentGenerations: [UUID: UUID] = [:]
    private var refreshing = false
    private var refreshAgain = false
    private(set) var isSwitching = false

    func open(_ folder: URL) {
        generation = UUID()
        invalidateDocument()
        watcher = nil
        reader = nil
        state = nil
        refreshing = false
        refreshAgain = false
        isSwitching = false
        let token = generation
        queue.async { [weak self] in
            let result = Result { let reader = try WorkspaceReader(folder: folder); return (reader, try reader.load()) }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                switch result {
                case .success(let (reader, state)):
                    self.reader = reader
                    self.state = state
                    self.watch(state)
                    self.onOpen?(state)
                case .failure(let error): self.onError?(error)
                }
            }
        }
    }

    func refresh() {
        guard let reader, !isSwitching else { return }
        if refreshing { refreshAgain = true; return }
        refreshing = true
        let token = generation
        queue.async { [weak self] in
            let result = Result { try reader.load() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.refreshing = false
                switch result {
                case .success(let state):
                    self.invalidateDocument()
                    self.state = state; self.onRefresh?(state)
                case .failure(let error): self.onError?(error)
                }
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }

    func read(_ path: String, diff: Bool, comparison: GitComparison = .workingTree, scope: UUID? = nil, completion: @escaping (Result<FileSnapshot, Error>) -> Void) {
        guard let reader, let state, !isSwitching else { return }
        let scope = scope ?? defaultDocumentScope
        let token = UUID()
        documentGenerations[scope] = token
        let workspaceToken = generation
        queue.async { [weak self] in
            let result = Result { try reader.snapshot(path: path, state: state, compare: diff, comparison: comparison) }
            DispatchQueue.main.async {
                guard let self, self.generation == workspaceToken, self.documentGenerations[scope] == token else { return }
                completion(result)
            }
        }
    }

    func invalidateDocument(scope: UUID? = nil) {
        if let scope { documentGenerations.removeValue(forKey: scope) }
        else { documentGenerations.removeAll() }
    }

    func destinations(completion: @escaping (Result<GitDestinations, Error>) -> Void) {
        guard let reader, !isSwitching else { return }
        let token = generation
        queue.async { [weak self] in
            let result = Result { try reader.git.destinations() }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                completion(result)
            }
        }
    }

    func activate(_ destination: GitDestination, completion: @escaping (Result<WorkspaceState, Error>) -> Void) {
        guard let reader, !isSwitching else { return }
        isSwitching = true
        generation = UUID()
        invalidateDocument()
        watcher = nil
        refreshing = false
        refreshAgain = false
        let token = generation
        queue.async { [weak self] in
            let result = Result {
                let targetRoot = try reader.git.activate(destination)
                let target = targetRoot == reader.root ? reader : try WorkspaceReader(folder: targetRoot)
                return (target, try target.load())
            }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.isSwitching = false
                switch result {
                case .success(let (target, state)):
                    self.reader = target
                    self.state = state
                    self.watch(state)
                    self.onOpen?(state)
                    completion(.success(state))
                case .failure(let error):
                    if let state = self.state { self.watch(state) }
                    completion(.failure(error))
                    self.refresh()
                }
            }
        }
    }
    private func watch(_ state: WorkspaceState) {
        watcher = FolderWatcher(root: state.root, additionalRoots: state.project.map { [$0.commonDirectory] } ?? []) { [weak self] in self?.refresh() }
    }
    func close() {
        generation = UUID()
        invalidateDocument()
        watcher = nil
        reader = nil
        state = nil
        refreshing = false
        refreshAgain = false
        isSwitching = false
    }
    deinit { watcher = nil }
}
