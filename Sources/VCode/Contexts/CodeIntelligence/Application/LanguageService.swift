import Foundation

final class LanguageService {
    var onStatus: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private let connection: LanguageServerConnection
    private let provider = LanguageProvider.typescript
    private var root: URL?
    private var documents: [String: (text: String, version: Int)] = [:]
    private var waiting: [(perform: () -> Void, cancel: ((Error) -> Void)?)] = []
    private var activeDocument: (url: URL, text: String, root: URL)?
    private var lastRecoveryAttempt = Date.distantPast

    init(resources: URL? = nil) {
        connection = LanguageServerConnection(resources: resources)
        connection.onStatus = { [weak self] text in self?.onStatus?(text) }
        connection.onFailure = { [weak self] error in
            guard let self else { return }
            let actions = self.waiting
            self.waiting.removeAll()
            actions.forEach { $0.cancel?(error) }
            self.onFailure?(error.localizedDescription)
        }
        connection.onReady = { [weak self] in
            guard let self else { return }
            let actions = self.waiting
            self.waiting.removeAll()
            actions.forEach { $0.perform() }
        }
    }

    func supports(_ path: String) -> Bool { provider.extensions.contains((path as NSString).pathExtension.lowercased()) }

    func open(url: URL, text: String, root: URL) {
        guard supports(url.path) else { return }
        if self.root != root { stop(); self.root = root }
        activeDocument = (url, text, root)
        if !connection.isRunning {
            documents.removeAll()
            let actions = waiting
            waiting.removeAll()
            let error = LanguageServiceError.connection(connection.failureReason ?? "Language service restarted.")
            actions.forEach { $0.cancel?(error) }
            connection.start(root: root)
        }
        let uri = url.absoluteString
        let action = { [weak self] in
            guard let self else { return }
            if let previous = self.documents[uri] {
                if previous.text != text {
                    let version = previous.version + 1
                    self.documents[uri] = (text, version)
                    self.connection.changeDocument(url: url, text: text, version: version)
                }
            } else {
                self.documents[uri] = (text, 1)
                self.connection.openDocument(url: url, text: text, languageID: self.provider.languageID(for: url))
            }
        }
        if connection.ready { onStatus?("TypeScript · Ready"); action() }
        else if connection.isRunning { waiting.append((action, nil)) }
    }

    func inspect(url: URL, line: Int, character: Int, kind: InspectionKind, completion: @escaping (Result<LanguageInspection, Error>) -> Void) {
        if !connection.isRunning {
            guard let document = activeDocument, document.url == url, Date().timeIntervalSince(lastRecoveryAttempt) >= 5 else {
                completion(.failure(LanguageServiceError.connection(connection.failureReason ?? "TypeScript language service is unavailable.")))
                return
            }
            lastRecoveryAttempt = Date()
            open(url: document.url, text: document.text, root: document.root)
        }
        let action: () -> Void = { [weak self] in
            self?.connection.inspect(location: CodeLocation(url: url, line: line, character: character), kind: kind, completion: completion)
        }
        if connection.ready { action() }
        else if connection.isRunning { waiting.append((action, { completion(.failure($0)) })) }
        else { completion(.failure(LanguageServiceError.connection(connection.failureReason ?? "TypeScript language service is unavailable."))) }
    }

    func stop() {
        let actions = waiting
        waiting.removeAll()
        actions.forEach { $0.cancel?(LanguageServiceError.connection("Language service stopped.")) }
        documents.removeAll()
        activeDocument = nil
        root = nil
        lastRecoveryAttempt = .distantPast
        connection.stop()
    }

    deinit { connection.stop() }
}
