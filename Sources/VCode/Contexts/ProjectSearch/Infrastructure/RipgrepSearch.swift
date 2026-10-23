import Foundation
import Darwin

final class ProjectSearchTask {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() {
        lock.lock(); stopped = true
        if process?.isRunning == true { process?.terminate() }
        lock.unlock()
    }
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw ProjectSearchError.cancelled }
        try process.run()
        self.process = process
    }
    func stopProcess() {
        lock.lock(); defer { lock.unlock() }
        if process?.isRunning == true { process?.terminate() }
    }
}

final class RipgrepSearch {
    private let queue = DispatchQueue(label: "dev.vcode.project-search", qos: .userInitiated)
    let executable: URL?
    static let maximumFileBytes = 4 * 1024 * 1024
    init(executable: URL? = RipgrepSearch.findExecutable()) { self.executable = executable }

    static func findExecutable() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Runtime/rg")
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("rg") }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/search-runtime/rg")
        return ([bundled].compactMap { $0 } + [development] + paths + [URL(fileURLWithPath: "/opt/homebrew/bin/rg"), URL(fileURLWithPath: "/usr/local/bin/rg")]).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult func search(root: URL, paths: [String], query: ProjectSearchQuery, limit: Int = 2000,
                                   completion: @escaping (Result<ProjectSearchResults, Error>) -> Void) -> ProjectSearchTask {
        let task = ProjectSearchTask()
        queue.async { [self] in
            let result = Result { try run(root: root, paths: paths, query: query, task: task, limit: limit) }
            DispatchQueue.main.async { if !task.isCancelled { completion(result) } }
        }
        return task
    }

    func run(root: URL, paths: [String], query: ProjectSearchQuery, task: ProjectSearchTask = ProjectSearchTask(), limit: Int = 2000) throws -> ProjectSearchResults {
        guard !query.text.isEmpty else { return ProjectSearchResults() }
        guard let executable else { throw ProjectSearchError.unavailable }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let exclusions = query.excludedFolders.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }.filter { !$0.isEmpty }
        var result = ProjectSearchResults()
        var candidates: [String] = []
        for path in Array(Set(paths)).sorted() {
            if task.isCancelled { throw ProjectSearchError.cancelled }
            guard !Self.excluded(path, folders: exclusions) else { continue }
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), url.path.hasPrefix(root.path + "/"),
                  url.resolvingSymlinksInPath().path == url.path,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { result.skippedFiles += 1; continue }
            if (attributes[.size] as? NSNumber)?.intValue ?? 0 > Self.maximumFileBytes { result.skippedFiles += 1; continue }
            candidates.append(path)
        }
        var batches: [[String]] = [], batch: [String] = [], bytes = 0
        for path in candidates {
            if bytes + path.utf8.count > 60_000 || batch.count >= 400 { batches.append(batch); batch = []; bytes = 0 }
            batch.append("./" + path); bytes += path.utf8.count + 3
        }
        if !batch.isEmpty { batches.append(batch) }
        if batches.isEmpty { batches = [["-"]] } // still validate a regular expression against empty stdin
        for paths in batches {
            if task.isCancelled { throw ProjectSearchError.cancelled }
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.currentDirectoryURL = root
            var arguments = ["--no-config", "--json", "--no-ignore", "--hidden", "--color=never", "--threads=2", "--encoding=utf-8", "--max-filesize=\(Self.maximumFileBytes)", query.caseSensitive ? "--case-sensitive" : "--ignore-case"]
            if !query.regularExpression { arguments.append("--fixed-strings") }
            if query.wholeWord { arguments.append("--word-regexp") }
            process.arguments = arguments + ["--regexp", query.text, "--"] + paths
            process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
            try task.start(process)
            defer { if process.isRunning { process.terminate() }; pipe.fileHandleForReading.closeFile() }
            var pending = Data(), diagnostic = ""
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 65_536)
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 10) {
                    let line = pending.prefix(upTo: newline)
                    pending.removeSubrange(...newline)
                    if line.count > 32_000_000 { task.stopProcess(); throw ProjectSearchError.failed("A matching line is too large to display. Narrow your search.") }
                    if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        if object["type"] as? String == "end", let data = object["data"] as? [String: Any], data["binary_offset"] is NSNumber,
                           let pathValue = data["path"] as? [String: Any], let rawPath = Self.text(pathValue) {
                            let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
                            result.matches.removeAll { $0.path == path }
                        }
                        if let match = Self.match(object), result.matches.count < limit { result.matches.append(match) }
                        else if object["type"] as? String == "match", result.matches.count >= limit {
                            result.limited = true; task.stopProcess()
                        }
                    } else if diagnostic.utf8.count < 4096 { diagnostic += String(decoding: line, as: UTF8.self) + "\n" }
                }
                if task.isCancelled { task.stopProcess() }
                if pending.count > 32_000_000 { task.stopProcess(); throw ProjectSearchError.failed("A matching line is too large to display. Narrow your search.") }
            }
            process.waitUntilExit()
            if task.isCancelled { throw ProjectSearchError.cancelled }
            if !result.limited && process.terminationStatus > 1 {
                let message = diagnostic.trimmingCharacters(in: .whitespacesAndNewlines)
                if result.matches.isEmpty { throw ProjectSearchError.failed(message.isEmpty ? "Search failed" : message) }
                result.warning = message.isEmpty ? "Some files could not be searched" : message
            }
            if result.limited { break }
        }
        result.matches.sort { $0.path == $1.path ? $0.line < $1.line : $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }

    private static func excluded(_ path: String, folders: [String]) -> Bool {
        let directories = path.split(separator: "/").dropLast().map(String.init)
        let prefixes = directories.indices.map { directories[...$0].joined(separator: "/") }
        return folders.contains { pattern in
            if !pattern.contains("/"), directories.contains(pattern) { return true }
            return (prefixes + [path]).contains { fnmatch(pattern, $0, 0) == 0 }
        }
    }

    static func match(_ object: [String: Any]) -> ProjectSearchMatch? {
        guard object["type"] as? String == "match", let data = object["data"] as? [String: Any],
              let pathValue = data["path"] as? [String: Any], let rawPath = text(pathValue),
              let lines = data["lines"] as? [String: Any], let source = text(lines), !source.contains("\0"),
              let number = data["line_number"] as? Int, let matches = data["submatches"] as? [[String: Any]] else { return nil }
        let bytes = Array(source.utf8)
        var byteOffset = 0, utf16Offset = 0
        func offset(_ boundary: Int) -> Int {
            utf16Offset += String(decoding: bytes[byteOffset..<boundary], as: UTF8.self).utf16.count
            byteOffset = boundary
            return utf16Offset
        }
        let ranges = matches.compactMap { match -> NSRange? in
            guard let start = match["start"] as? Int, let end = match["end"] as? Int, start >= byteOffset, end >= start, end <= bytes.count else { return nil }
            let location = offset(start), finish = offset(end)
            return NSRange(location: location, length: finish - location)
        }
        guard !ranges.isEmpty else { return nil }
        let path = rawPath.hasPrefix("./") ? String(rawPath.dropFirst(2)) : rawPath
        return ProjectSearchMatch(path: path, line: max(0, number - 1), text: source.trimmingCharacters(in: .newlines), ranges: ranges)
    }
    private static func text(_ value: [String: Any]) -> String? {
        if let text = value["text"] as? String { return text }
        return (value["bytes"] as? String).flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
    }
}
