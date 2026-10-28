import Foundation
import CryptoKit

/// One working copy per repository path, shared by all editor groups. Recovery
/// contents are user data; layout snapshots continue to contain paths only.
final class SourceEditStore {
    struct Buffer: Codable {
        let root: URL
        let path: String
        var baseline: Data
        var text: String
        var needsSave: Bool { encoded != baseline }
        var encoded: Data {
            let bom = baseline.starts(with: [0xef, 0xbb, 0xbf]) ? Data([0xef, 0xbb, 0xbf]) : Data()
            return bom + Data(text.utf8)
        }
    }

    let directory: URL
    private(set) var root: URL?
    private var files: FileBrowser?
    private var buffers: [String: Buffer] = [:]
    private var observers: [UUID: (String, UUID?) -> Void] = [:]
    private var pending = Set<String>()
    private var recoveryWork: DispatchWorkItem?
    var onError: ((Error) -> Void)?
    var dirtyPaths: [String] { buffers.keys.filter { buffers[$0]?.needsSave == true }.sorted() }

    init(directory: URL = XDGDirectories().data.appendingPathComponent("source-edits", isDirectory: true)) { self.directory = directory }

    func activate(_ root: URL) throws {
        let files = try FileBrowser(root: root)
        guard self.root != files.root else { return }
        try flush()
        self.root = files.root
        self.files = files
        buffers = [:]
    }

    func observe(_ id: UUID, _ callback: @escaping (String, UUID?) -> Void) { observers[id] = callback }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func buffer(_ path: String) -> Buffer? { buffers[path] }

    func restoreRecovery(_ path: String) throws {
        guard let root, let files, buffers[path] == nil else { return }
        _ = try files.safeURL(path)
        let url = recoveryURL(path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let recovered = try JSONDecoder().decode(Buffer.self, from: Data(contentsOf: url))
        guard recovered.root == root, recovered.path == path else { throw failure("The recovered file belongs to a different project.") }
        buffers[path] = recovered
    }

    @discardableResult
    func open(_ path: String) throws -> Buffer {
        guard let root, let files else { throw failure("No project is open.") }
        if let existing = buffers[path], existing.needsSave { return existing }
        try restoreRecovery(path)
        if let recovered = buffers[path], recovered.needsSave { return recovered }
        let content = try read(path, files: files)
        let data = content.starts(with: [0xef, 0xbb, 0xbf]) ? content.dropFirst(3) : content[...]
        let buffer = Buffer(root: root, path: path, baseline: content, text: String(decoding: data, as: UTF8.self))
        let changedExternally = buffers[path].map { $0.baseline != content } ?? false
        buffers[path] = buffer
        if changedExternally { notify(path, sender: nil) }
        return buffer
    }

    func update(_ path: String, text: String, sender: UUID) {
        guard var buffer = buffers[path], buffer.text != text else { return }
        buffer.text = text
        buffers[path] = buffer
        pending.insert(path)
        recoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            do { try self?.flush() } catch { self?.onError?(error) }
        }
        recoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        notify(path, sender: sender)
    }

    func save(_ path: String) throws {
        guard var buffer = buffers[path], let files else { throw failure("This file is not open for editing.") }
        guard buffer.needsSave else { return }
        let current = try read(path, files: files)
        guard current == buffer.baseline else {
            throw failure("This file changed outside VCode. Your edits are preserved. Use Save As to keep both versions.")
        }
        let url = try files.safeURL(path)
        // Coordinated atomic replacement preserves the original until writing
        // succeeds. Check the bytes again inside coordination, never timestamps.
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do {
                guard try read(path, files: files) == buffer.baseline else { throw failure("This file changed outside VCode. Use Save As to keep both versions.") }
                let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
                try buffer.encoded.write(to: target, options: .atomic)
                if let permissions = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
            } catch { writeError = error }
        }
        if let error = coordinationError { throw error }
        if let error = writeError { throw error }
        buffer.baseline = buffer.encoded
        buffers[path] = buffer
        pending.insert(path)
        try flush()
        notify(path, sender: nil)
    }

    /// Save As exports a copy; it does not silently change this tab's identity
    /// or treat the original file's outstanding edits as saved.
    func export(_ path: String, to destination: URL) throws {
        guard let buffer = buffers[path] else { throw failure("This file is not open for editing.") }
        guard destination.standardizedFileURL.resolvingSymlinksInPath() != buffer.root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath() else { try save(path); return }
        try buffer.encoded.write(to: destination, options: .atomic)
    }

    func discard(_ path: String) throws {
        let url = recoveryURL(path)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        pending.remove(path)
        buffers.removeValue(forKey: path)
        notify(path, sender: nil)
    }

    func flush() throws {
        recoveryWork?.cancel(); recoveryWork = nil
        for path in Array(pending) {
            guard let buffer = buffers[path] else { pending.remove(path); continue }
            let url = recoveryURL(path)
            if buffer.needsSave {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(buffer).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            pending.remove(path)
        }
    }

    private func read(_ path: String, files: FileBrowser) throws -> Data {
        guard files.exists(path) else { throw failure("The file was deleted or moved. Your edits are preserved; use Save As to keep them.") }
        let content = try files.read(path, maximumByteCount: FileSnapshot.maximumByteCount)
        guard content.message == nil, !content.isBinary else { throw failure(content.message ?? "This is not a UTF-8 text file.") }
        return content.data
    }
    private func recoveryURL(_ path: String) -> URL {
        let identity = (root?.path ?? "") + "\0" + path
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key + ".json")
    }
    private func notify(_ path: String, sender: UUID?) { Array(observers.values).forEach { $0(path, sender) } }
    private func failure(_ description: String) -> NSError { NSError(domain: "VCode.SourceEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
}
