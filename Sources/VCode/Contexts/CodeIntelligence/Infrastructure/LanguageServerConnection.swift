import Foundation

final class LanguageServerConnection {
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    private let resources: URL
    // A ceiling, not an allocation: real projects can exceed 512 MB while loading.
    private let memoryLimitMB = 2048
    private var diagnosticTail = ""
    private var heapExhausted = false
    private(set) var failureReason: String?
    private let serverPath = "TypeScript/node_modules/typescript-language-server/lib/cli.mjs"
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var nextID = 0
    private var pending: [Int: (Result<Any, Error>) -> Void] = [:]
    private var requestTimeouts: [Int: DispatchWorkItem] = [:]
    private var generation = UUID()
    private var root: URL?
    private let readQueue = DispatchQueue(label: "vcode.lsp.read", qos: .userInitiated)
    private(set) var ready = false
    var isRunning: Bool { process?.isRunning == true }

    init(resources: URL? = Bundle.main.resourceURL) {
        self.resources = resources ?? URL(fileURLWithPath: "")
    }

    func stop() {
        shutdown(error: LanguageServiceError.connection("Language service stopped."))
        failureReason = nil
        diagnosticTail = ""
        heapExhausted = false
    }

    private func shutdown(error: Error) {
        generation = UUID()
        ready = false
        requestTimeouts.values.forEach { $0.cancel() }
        requestTimeouts.removeAll()
        let callbacks = Array(pending.values)
        pending.removeAll()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            notify("exit", [:])
            process?.terminate()
        }
        try? input?.close()
        try? output?.close()
        try? errors?.close()
        input = nil
        output = nil
        errors = nil
        process = nil
        root = nil
        callbacks.forEach { $0(.failure(error)) }
    }

    private func fail(_ reason: String, status: String) {
        failureReason = reason
        shutdown(error: LanguageServiceError.connection(reason))
        onStatus?(status)
        onFailure?(LanguageServiceError.connection(reason))
    }

    private func recordDiagnostic(_ text: String) {
        diagnosticTail = String((diagnosticTail + text + "\n").suffix(8192))
        let lower = text.lowercased()
        if lower.contains("heap out of memory") || lower.contains("heap limit") || lower.contains("allocation failed") {
            heapExhausted = true
        }
    }

    func start(root: URL) {
        stop()
        self.root = root
        var script = resources.appendingPathComponent(serverPath)
        if !FileManager.default.fileExists(atPath: script.path) {
            let sourceRoot = String(#filePath.prefix(through: #filePath.range(of: "/Sources/")!.lowerBound))
            script = URL(fileURLWithPath: sourceRoot).appendingPathComponent("Tools").appendingPathComponent(serverPath)
        }
        let candidates = [
            resources.appendingPathComponent("Runtime/node").path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".volta/bin/node").path,
            "/opt/homebrew/bin/node", "/usr/local/bin/node"
        ]
        guard let node = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              FileManager.default.fileExists(atPath: script.path) else {
            fail("TypeScript runtime or language server is missing from the application.", status: "TypeScript · Setup needed")
            return
        }
        onStatus?("TypeScript · Starting…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = ["--max-old-space-size=256", script.path, "--stdio", "--log-level", "1"]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        self.process = process
        let token = generation
        var framer = LSPFramer()
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.readQueue.async { [weak self] in
                do {
                    let messages = try framer.append(data)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        messages.forEach { self.receive($0) }
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.fail(error.localizedDescription, status: "TypeScript · Connection failed")
                    }
                }
            }
        }
        errors?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.recordDiagnostic(String(decoding: data, as: UTF8.self))
            }
        }
        process.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            self?.readQueue.async { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    if self.heapExhausted {
                        self.fail("TypeScript ran out of memory (heap limit: \(self.memoryLimitMB) MB).", status: "TypeScript · Out of memory")
                    } else {
                        let detail = self.diagnosticTail.components(separatedBy: .newlines).first { $0.hasPrefix("Error:") }
                        let reason = detail.map { "TypeScript stopped: " + String($0.prefix(240)) } ?? "TypeScript stopped unexpectedly (exit code: \(code))."
                        self.fail(reason, status: "TypeScript · Stopped")
                    }
                }
            }
        }
        do {
            try process.run()
            request("initialize", [
                "processId": ProcessInfo.processInfo.processIdentifier,
                "clientInfo": ["name": "VCode", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"],
                "rootUri": root.absoluteString,
                "workspaceFolders": [["uri": root.absoluteString, "name": root.lastPathComponent]],
                "capabilities": ["general": ["positionEncodings": ["utf-16"]], "workspace": ["configuration": true, "workspaceFolders": true], "textDocument": ["hover": ["contentFormat": ["markdown", "plaintext"]], "definition": ["linkSupport": true], "synchronization": ["dynamicRegistration": false]]],
                "initializationOptions": ["hostInfo": "vcode", "disableAutomaticTypingAcquisition": true, "maxTsServerMemory": memoryLimitMB, "tsserver": ["useSyntaxServer": "never", "path": script.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("typescript/lib/tsserver.js").path]]
            ]) { [weak self] result in
                guard let self, self.generation == token else { return }
                switch result {
                case .success:
                    self.notify("initialized", [:])
                    self.ready = true
                    self.onStatus?("TypeScript · Ready")
                    self.onReady?()
                case .failure(let error):
                    self.fail("TypeScript initialization failed: " + error.localizedDescription, status: "TypeScript · Failed to start")
                }
            }
        } catch {
            fail("TypeScript could not start: " + error.localizedDescription, status: "TypeScript · Failed to start")
        }
    }

    func openDocument(url: URL, text: String, languageID: String) {
        notify("textDocument/didOpen", ["textDocument": ["uri": url.absoluteString, "languageId": languageID, "version": 1, "text": text]])
    }

    func changeDocument(url: URL, text: String, version: Int) {
        notify("textDocument/didChange", ["textDocument": ["uri": url.absoluteString, "version": version], "contentChanges": [["text": text]]])
    }

    func inspect(location: CodeLocation, kind: InspectionKind, completion: @escaping (Result<LanguageInspection, Error>) -> Void) {
        var params: [String: Any] = ["textDocument": ["uri": location.url.absoluteString], "position": ["line": location.line, "character": location.character]]
        if kind == .references { params["context"] = ["includeDeclaration": false] }
        request("textDocument/" + kind.rawValue, params) { [weak self] result in
            let decoded = result.flatMap { value in Result { try LSPInspectionMapper.decode(value, kind: kind) } }
            guard kind == .references, case .success(.locations(let references)) = decoded, !references.isEmpty else { completion(decoded); return }
            guard let self else { completion(.failure(LanguageServiceError.connection("Language service stopped."))); return }
            // The TS server may mark an import alias as the definition while
            // returning its original declaration as an ordinary reference.
            // Resolve the actual target as well, so includeDeclaration:false
            // has the same meaning when queried from a declaration or a use.
            self.inspect(location: location, kind: .definition) { result in
                completion(result.map { value in
                    guard case .locations(let definitions) = value else { return .locations(references) }
                    let targets = Set(definitions.map { CodeLocation(url: $0.url.standardizedFileURL, line: $0.line, character: $0.character) })
                    return .locations(references.filter { !targets.contains(CodeLocation(url: $0.url.standardizedFileURL, line: $0.line, character: $0.character)) })
                })
            }
        }
    }

    private func request(_ method: String, _ params: [String: Any], completion: @escaping (Result<Any, Error>) -> Void) {
        nextID += 1
        let id = nextID
        pending[id] = completion
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, let callback = self.pending.removeValue(forKey: id) else { return }
            self.requestTimeouts.removeValue(forKey: id)
            self.notify("$/cancelRequest", ["id": id])
            callback(.failure(LanguageServiceError.connection("TypeScript did not respond in time.")))
        }
        requestTimeouts[id] = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
        send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func notify(_ method: String, _ params: [String: Any]) { send(["jsonrpc": "2.0", "method": method, "params": params]) }

    private func send(_ message: [String: Any]) {
        guard let data = try? LSPFramer.encode(message) else { return }
        do { try input?.write(contentsOf: data) } catch { onStatus?("TypeScript · Connection closed") }
    }

    private func receive(_ message: [String: Any]) {
        if message["method"] as? String == "window/logMessage", let params = message["params"] as? [String: Any], let text = params["message"] as? String {
            recordDiagnostic(text)
            return
        }
        if let id = message["id"], let method = message["method"] as? String {
            let result: Any
            if method == "workspace/configuration" {
                let items = (message["params"] as? [String: Any])?["items"] as? [Any] ?? []
                result = items.map { _ in [String: Any]() }
            } else if method == "workspace/workspaceFolders", let root {
                result = [["uri": root.absoluteString, "name": root.lastPathComponent]]
            } else {
                result = NSNull()
            }
            send(["jsonrpc": "2.0", "id": id, "result": result])
        } else if let id = message["id"] as? Int, let completion = pending.removeValue(forKey: id) {
            requestTimeouts.removeValue(forKey: id)?.cancel()
            if let error = message["error"] as? [String: Any] {
                completion(.failure(LanguageServiceError.connection(error["message"] as? String ?? "Language service error.")))
            } else {
                completion(.success(message["result"] ?? NSNull()))
            }
        }
    }
}
