import Foundation

struct ReadingDocument: Equatable {
    let path: String
    let comparison: GitComparison?
    var id: String { (comparison?.rawValue ?? "source") + "\0" + path }
}

struct ReaderSession {
    private(set) var documents: [ReadingDocument] = []
    private(set) var activeDocument: ReadingDocument?
    var paths: [String] { documents.map(\.path) }
    var activePath: String? { activeDocument?.path }

    mutating func open(_ path: String, comparison: GitComparison? = nil) {
        let document = ReadingDocument(path: path, comparison: comparison)
        if !documents.contains(document) { documents.append(document) }
        activeDocument = document
    }

    @discardableResult
    mutating func close(_ path: String) -> Bool {
        guard let document = documents.first(where: { $0.path == path }) else { return false }
        return close(document)
    }

    @discardableResult
    mutating func close(_ document: ReadingDocument) -> Bool {
        guard let index = documents.firstIndex(of: document) else { return false }
        let wasActive = activeDocument == document
        documents.remove(at: index)
        if wasActive { activeDocument = documents.isEmpty ? nil : documents[min(index, documents.count - 1)] }
        return wasActive
    }

    mutating func reset() { documents = []; activeDocument = nil }
}
