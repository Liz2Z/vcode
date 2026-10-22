import Foundation

final class FileBrowser {
    private let store: SourceFileStore
    var root: URL { store.root }

    init(root: URL) throws { store = try SourceFileStore(root: root) }
    func list() throws -> [String] { try store.list() }
    func read(_ path: String, maximumByteCount: Int) throws -> SourceContent {
        try store.read(path, maximumByteCount: maximumByteCount)
    }
    func safeURL(_ path: String) throws -> URL { try store.url(for: path) }
}
