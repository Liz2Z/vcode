import Foundation

final class GitCLI: GitRepository {
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    func repositoryRoot() -> URL? {
        guard let data = try? read(["rev-parse", "--show-toplevel"]) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
    }

    func status() throws -> GitStatus? {
        let data = try run(arguments: ["--no-optional-locks", "-c", "core.fsmonitor=false", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], allowedExitCodes: [0, 128])
        let fields = Self.paths(data)
        guard let oid = fields.first(where: { $0.hasPrefix("# branch.oid ") }) else { return nil }
        let hasHead = !oid.hasSuffix("(initial)")
        let head = fields.first(where: { $0.hasPrefix("# branch.head ") }).map { String($0.dropFirst(14)) } ?? ""
        let branch: String
        if head == "(detached)" {
            branch = String(decoding: try read(["rev-parse", "--short", "HEAD"]), as: UTF8.self).trimmingCharacters(in: .newlines)
        } else { branch = head }
        // Reuse the comparison mapper after decoding v2's fixed metadata fields.
        var records: [String] = []
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            if entry.hasPrefix("? ") { records.append("?? " + entry.dropFirst(2)); continue }
            let kind = entry.first
            let count = kind == "1" ? 8 : kind == "2" ? 9 : kind == "u" ? 10 : 0
            guard count > 0 else { continue }
            let values = entry.split(separator: " ", maxSplits: count, omittingEmptySubsequences: false)
            guard values.count == count + 1 else { throw GitError.command("Git returned an invalid status record.") }
            records.append(values[1].replacingOccurrences(of: ".", with: " ") + " " + values[count])
            if kind == "2" {
                guard index < fields.count else { throw GitError.command("Git returned an incomplete rename record.") }
                records.append(fields[index]); index += 1
            }
        }
        return GitStatus(root: root, branch: branch, changes: Self.changes(Data((records.joined(separator: "\0") + "\0").utf8)), hasHead: hasHead)
    }

    func ignoredPaths() throws -> Set<String> {
        // Let Git collapse ignored, untracked directories before disk traversal.
        // Directories containing tracked exceptions are not collapsed away.
        let output = try read(["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"])
        return Set(Self.paths(output))
    }

    func projectIdentity() throws -> GitProject {
        let data = try read(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        let common = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let primary = Self.worktrees(try read(["worktree", "list", "--porcelain", "-z"])).first?.root ?? root
        return GitProject(commonDirectory: common, primaryRoot: primary)
    }

    static func changes(_ data: Data) -> [GitChange] {
        let fields = paths(data)
        var result: [GitChange] = []
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            guard entry.utf8.count >= 3 else { continue }
            let codes = Array(entry.prefix(2))
            let path = String(entry.dropFirst(3))
            let renamed = codes.contains("R") || codes.contains("C")
            let original = renamed && index < fields.count ? fields[index] : nil
            if renamed { index += 1 }
            if codes == ["?", "?"] {
                result.append(GitChange(path: path, kind: .untracked, comparison: .unstaged))
            } else if codes.contains("U") || codes == ["A", "A"] || codes == ["D", "D"] {
                result.append(GitChange(path: path, kind: .conflict, comparison: .unstaged))
            } else {
                if codes[0] != " " {
                    result.append(GitChange(path: path, originalPath: codes[0] == "R" || codes[0] == "C" ? original : nil,
                                            kind: GitChangeKind(rawValue: String(codes[0])) ?? .modified, comparison: .staged))
                }
                if codes[1] != " " {
                    result.append(GitChange(path: path, originalPath: codes[1] == "R" || codes[1] == "C" ? original : nil,
                                            kind: GitChangeKind(rawValue: String(codes[1])) ?? .modified, comparison: .unstaged))
                }
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func content(at revision: GitRevision, path: String, maximumByteCount: Int) throws -> Data {
        let object: String
        switch revision {
        case .head:
            object = "HEAD:" + path
        case .index:
            object = ":0:" + path
        }
        // Batch-check returns size or "missing" in one invocation, preserving
        // NUL-delimited input for paths containing line breaks.
        let sizeData = try run(arguments: ["--no-optional-locks", "cat-file", "--batch-check=%(objectsize)", "-z"], input: Data((object + "\0").utf8))
        let sizeText = String(decoding: sizeData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if sizeText.hasSuffix(" missing") { return Data() }
        guard let size = Int(sizeText) else { throw GitError.command("Git returned an invalid object size.") }
        if size > maximumByteCount { throw GitError.contentTooLarge }
        let data = try read(["show", object])
        if data.count > maximumByteCount { throw GitError.contentTooLarge }
        return data
    }

    func destinations() throws -> GitDestinations {
        let worktrees = Self.worktrees(try read(["worktree", "list", "--porcelain", "-z"]))
        let data = try read(["for-each-ref", "--format=%(refname)", "refs/heads/"])
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { ref -> String? in
            guard ref.hasPrefix("refs/heads/") else { return nil }
            return String(ref.dropFirst("refs/heads/".count))
        }
        let current = try? read(["symbolic-ref", "--quiet", "--short", "HEAD"])
        let branch = current.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
        return GitDestinations(root: root, currentBranch: branch, branches: names.map { name in
            GitBranch(name: name, worktree: worktrees.first { $0.branch == name && !$0.isBare }?.root)
        }, worktrees: worktrees)
    }

    func switchBranch(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), (try? read(["show-ref", "--verify", "--quiet", "refs/heads/" + name])) != nil else {
            throw GitError.command("This local branch no longer exists. Refresh the branch list.")
        }
        _ = try run(arguments: ["-c", "core.fsmonitor=false", "switch", "--no-guess", "--no-recurse-submodules", "--", name])
    }

    func validatedWorktreeRoot(_ root: URL) throws -> URL {
        guard GitCLI(root: root).repositoryRoot() == root else {
            throw GitError.command("This folder is no longer the selected worktree.")
        }
        return root
    }

    static func worktrees(_ data: Data) -> [GitWorktree] {
        var result: [GitWorktree] = []
        var attributes: [String: String] = [:]
        func finish() {
            guard let path = attributes["worktree"] else { attributes = [:]; return }
            var existing = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            var suffix: [String] = []
            while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
                suffix.append(existing.lastPathComponent)
                existing.deleteLastPathComponent()
            }
            let url = suffix.reversed().reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1, isDirectory: true) }
            let ref = attributes["branch"]
            let branch = ref.flatMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
            let bare = attributes["bare"] != nil
            let prunable = attributes["prunable"] != nil
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
            result.append(GitWorktree(root: url, branch: branch, head: attributes["HEAD"] ?? "", isBare: bare, isAvailable: exists && !bare && !prunable, note: prunable ? "Missing worktree" : bare ? "Bare repository" : attributes["locked"] != nil ? "Locked" : nil))
            attributes = [:]
        }
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty { finish(); continue }
            let value = String(decoding: field, as: UTF8.self)
            let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            attributes[String(parts[0])] = parts.count == 2 ? String(parts[1]) : ""
        }
        finish()
        return result
    }

    private func read(_ arguments: [String]) throws -> Data {
        try run(arguments: ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false"] + arguments)
    }

    static func paths(_ data: Data) -> [String] {
        data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    func patch(before: Data, after: Data) throws -> String {
        if before == after { return "" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = folder.appendingPathComponent("before")
        let new = folder.appendingPathComponent("after")
        try before.write(to: old)
        try after.write(to: new)
        let data = try run(arguments: ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--no-color", "--text", "--unified=0", "--", old.path, new.path], allowedExitCodes: [0, 1])
        return String(decoding: data, as: UTF8.self)
    }

    private func run(arguments: [String], allowedExitCodes: Set<Int32> = [0], input: Data? = nil) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        // A file avoids blocking on a full stdin pipe while Git writes stdout.
        let inputFile = input.map { _ in FileManager.default.temporaryDirectory.appendingPathComponent("vcode-stdin-" + UUID().uuidString) }
        var inputHandle: FileHandle?
        defer {
            try? inputHandle?.close()
            if let inputFile { try? FileManager.default.removeItem(at: inputFile) }
        }
        if let input, let inputFile {
            try input.write(to: inputFile)
            inputHandle = try FileHandle(forReadingFrom: inputFile)
            process.standardInput = inputHandle
        }
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let output = Pipe()
        let errorFile = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-stderr-" + UUID().uuidString)
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorFile)
        defer { try? errorHandle.close(); try? FileManager.default.removeItem(at: errorFile) }
        process.standardOutput = output
        process.standardError = errorHandle
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        let timeout = DispatchWorkItem { [weak process] in if let process, process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        // waitUntilExit polls the run loop and adds ~70 ms after stdout closes
        // on this macOS version. The termination handler signals immediately.
        finished.wait()
        timeout.cancel()
        guard allowedExitCodes.contains(process.terminationStatus) else {
            let message = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? "Git could not read this repository."
            throw GitError.command(message.isEmpty ? "Git could not read this repository." : message)
        }
        return data
    }
}
