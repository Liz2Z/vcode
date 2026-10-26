import Foundation

final class FileBrowser {
    private let store: SourceFileStore
    var root: URL { store.root }

    init(root: URL) throws { store = try SourceFileStore(root: root) }
    func list(excluding paths: Set<String> = []) throws -> [String] { try store.list(excluding: paths) }
    func listing(excluding paths: Set<String> = []) throws -> FileListing { try store.listing(excluding: paths) }
    func children(in directory: String) throws -> [FileTreeEntry] { try store.children(in: directory) }
    func exists(_ path: String) -> Bool { store.exists(path) }
    func read(_ path: String, maximumByteCount: Int) throws -> SourceContent {
        try store.read(path, maximumByteCount: maximumByteCount)
    }
    func safeURL(_ path: String) throws -> URL { try store.url(for: path) }
}
