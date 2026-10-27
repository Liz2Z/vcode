import Foundation
import Darwin

final class SourceFileStore {
    let root: URL

    init(root: URL) throws {
        let normalized = root.standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &directory), directory.boolValue else {
            throw FileAccessError.unavailableFolder
        }
        self.root = normalized
    }

    func read(_ path: String, maximumByteCount: Int) throws -> SourceContent {
        let url = try url(for: path)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let attributes = exists ? try FileManager.default.attributesOfItem(atPath: url.path) : [:]
        if let size = attributes[.size] as? NSNumber, size.intValue > maximumByteCount { throw FileAccessError.tooLarge }
        if let type = attributes[.type] as? FileAttributeType, type == .typeSymbolicLink {
            return SourceContent(data: Data(), message: "Symbolic link · " + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path)))
        }
        if exists, let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            return SourceContent(data: Data(), message: "This item cannot be previewed as a text file.")
        }
        return SourceContent(data: exists ? try Data(contentsOf: url) : Data(), message: nil)
    }

    func url(for path: String) throws -> URL {
        let url = root.appendingPathComponent(path).standardizedFileURL
        guard !path.isEmpty, !path.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else { throw FileAccessError.invalidPath }
        // Never follow links outside the repository, including links in ancestor directories.
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == root.path || parent.hasPrefix(root.path + "/") else { throw FileAccessError.invalidPath }
        return url
    }

    func list(excluding paths: Set<String> = []) throws -> [String] { try listing(excluding: paths).paths }

    func exists(_ path: String) -> Bool {
        guard let url = try? url(for: path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func listing(excluding paths: Set<String> = []) throws -> FileListing {
        let ignored: Set<String> = ["node_modules", ".build", ".swiftpm", "dist", "build"]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return FileListing(paths: [], identities: [:]) }
        var files: [String] = []
        var searchable: [String] = []
        var directories: [String] = []
        var deferred: Set<String> = []
        var identities: [String: AnyHashable] = [:]
        // DirectoryEnumerator emits physical /private/var URLs even when
        // Foundation normalizes the root to /var. Resolve that prefix once.
        let physicalRoot = root.withUnsafeFileSystemRepresentation { path -> String in
            guard let path, let resolved = realpath(path, nil) else { return root.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let prefix = physicalRoot == "/" ? "/" : physicalRoot + "/"
        while let url = enumerator.nextObject() as? URL {
            let absolute = url.path
            guard absolute.hasPrefix(prefix) else { continue }
            let path = String(absolute.dropFirst(prefix.count))
            // Files can disappear between enumeration and metadata lookup.
            let resource: URLResourceValues
            do { resource = try url.resourceValues(forKeys: keys) }
            catch CocoaError.fileReadNoSuchFile { continue }
            if !ProjectFileVisibility.isVisible(path) {
                // On a regular file, skipDescendants can skip the next directory.
                if resource.isDirectory == true && resource.isSymbolicLink != true { enumerator.skipDescendants() }
                continue
            }
            let excluded = ignored.contains(url.lastPathComponent) || paths.contains(path) || paths.contains(path + "/")
            if resource.isDirectory == true && resource.isSymbolicLink != true {
                directories.append(path)
                if excluded {
                    deferred.insert(path)
                    enumerator.skipDescendants()
                }
                continue
            }
            // DirectoryEnumerator does not follow symbolic links. Calling
            // skipDescendants on a link can also skip an unrelated directory.
            if resource.isRegularFile == true || resource.isSymbolicLink == true {
                // root is already canonical and links are never traversed, so
                // there is no need to resolve every file's parent again.
                files.append(path)
                if !excluded { searchable.append(path) }
                if let identity = resource.fileResourceIdentifier as? AnyHashable { identities[path] = identity }
            }
        }
        return FileListing(paths: files.sorted(), identities: identities, directories: directories.sorted(),
                           deferredDirectories: deferred, searchablePaths: searchable.sorted())
    }

    // Read only one requested level; never descend into dependency/build trees.
    func children(in directory: String) throws -> [FileTreeEntry] {
        let url = directory.isEmpty ? root : try self.url(for: directory)
        let metadata = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { throw FileAccessError.invalidPath }
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).compactMap { child in
            guard ProjectFileVisibility.isVisible(child.lastPathComponent) else { return nil }
            let resource: URLResourceValues
            do { resource = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            return FileTreeEntry(name: child.lastPathComponent,
                                 path: directory.isEmpty ? child.lastPathComponent : directory + "/" + child.lastPathComponent,
                                 directory: resource.isDirectory == true && resource.isSymbolicLink != true)
        }.sorted { $0.directory == $1.directory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.directory }
    }
}
