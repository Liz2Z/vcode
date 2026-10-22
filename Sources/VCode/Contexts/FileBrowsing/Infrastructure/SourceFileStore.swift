import Foundation

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

    func list() throws -> [String] {
        let ignored: Set<String> = [".git", "node_modules", ".build", ".swiftpm", "dist", "build", ".DS_Store"]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else { return [] }
        var files: [String] = []
        while let url = enumerator.nextObject() as? URL {
            if ignored.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if resource.isSymbolicLink == true { enumerator.skipDescendants() }
            if resource.isRegularFile == true || resource.isSymbolicLink == true {
                let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath()
                let normalized = resolvedParent.appendingPathComponent(url.lastPathComponent).standardizedFileURL
                let components = normalized.pathComponents
                let rootComponents = root.pathComponents
                guard components.starts(with: rootComponents) else { continue }
                files.append(components.dropFirst(rootComponents.count).joined(separator: "/"))
            }
        }
        return files.sorted()
    }

}
