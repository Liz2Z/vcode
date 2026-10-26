import Foundation

struct FileTreeEntry {
    let name: String
    let path: String
    let directory: Bool
}

struct FileTreeIndex {
    private let paths: [String]
    init(paths: [String]) { self.paths = paths.sorted() }

    func children(in directory: String) -> [FileTreeEntry] {
        let prefix = directory.isEmpty ? "" : directory + "/"
        var index = lowerBound(prefix)
        var result: [FileTreeEntry] = []
        while index < paths.count, paths[index].hasPrefix(prefix) {
            let suffix = paths[index].dropFirst(prefix.count)
            // A trailing-slash marker represents this folder, not a child file.
            if suffix.isEmpty { index += 1; continue }
            if let slash = suffix.firstIndex(of: "/") {
                let name = String(suffix[..<slash])
                let path = prefix + name
                result.append(FileTreeEntry(name: name, path: path, directory: true))
                // Skip an entire unopened subtree without allocating its nodes.
                index = end(of: path + "/", startingAt: index)
            } else {
                result.append(FileTreeEntry(name: String(suffix), path: paths[index], directory: false))
                index += 1
            }
        }
        return result.sorted { $0.directory == $1.directory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.directory }
    }

    private func lowerBound(_ prefix: String) -> Int {
        var low = 0, high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if paths[middle] < prefix { low = middle + 1 } else { high = middle }
        }
        return low
    }
    private func end(of prefix: String, startingAt start: Int) -> Int {
        var low = start, high = paths.count
        while low < high {
            let middle = (low + high) / 2
            if paths[middle].hasPrefix(prefix) { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
