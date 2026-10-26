import Foundation
import CoreServices
import Darwin

final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void
    private let rootPath: String
    private let metadataPaths: [String]
    private let visibleDirectories: () -> Set<String>
    private let openedFiles: () -> Set<String>
    private let deferredDirectories: () -> Set<String>

    init(root: URL, additionalRoots: [URL] = [], visibleDirectories: @escaping () -> Set<String> = { [] },
         openedFiles: @escaping () -> Set<String> = { [] }, deferredDirectories: @escaping () -> Set<String> = { [] }, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.visibleDirectories = visibleDirectories; self.openedFiles = openedFiles; self.deferredDirectories = deferredDirectories
        rootPath = Self.physicalPath(root)
        metadataPaths = additionalRoots.map(Self.physicalPath)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            let needsRescan = (0..<count).contains { flags[$0] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 }
            guard needsRescan || changed.contains(where: watcher.isRelevant), watcher.pending == nil else { return }
            let work = DispatchWorkItem { [weak watcher] in
                watcher?.pending = nil
                watcher?.onChange()
            }
            watcher.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
        let paths = Array(Set([rootPath] + metadataPaths))
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    private func isRelevant(_ path: String) -> Bool {
        // Event paths are physical, including deleted paths which can no longer
        // be resolved. Canonicalize existing roots once, never the changed leaf.
        for metadata in metadataPaths where path == metadata || path.hasPrefix(metadata + "/") {
            let relative = String(path.dropFirst(metadata.count)).split(separator: "/")
            // Object and reflog writes do not change the visible checkout. HEAD,
            // index and refs also cover Git metadata outside a linked worktree.
            return relative.isEmpty || ["HEAD", "index", "refs", "packed-refs", "config", "worktrees"].contains(String(relative[0]))
        }
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(path.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let visible = visibleDirectories()
        if openedFiles().contains(relative) || visible.contains(relative) || visible.contains((relative as NSString).deletingLastPathComponent) { return true }
        // Observe creation/removal of a deferred root itself, but not writes
        // deep inside an unopened dependency or generated folder.
        for directory in deferredDirectories() {
            if relative == directory { return true }
            if relative.hasPrefix(directory + "/") { return false }
        }
        return !relative.split(separator: "/").dropLast().contains(where: { ["node_modules", ".build", ".swiftpm", "dist", "build"].contains(String($0)) })
    }

    private static func physicalPath(_ url: URL) -> String {
        url.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer, let resolved = realpath(pointer, nil) else { return url.path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    deinit {
        pending?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
