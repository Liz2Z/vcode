import Foundation

struct ReadingDocument: Codable, Hashable {
    let path: String
    let comparison: GitComparison?
    var id: String { (comparison?.rawValue ?? "source") + "\0" + path }
}

enum ReadingCloseScope: CaseIterable {
    case all, others, right, left
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
        remove([document])
    }

    func documentsToClose(_ scope: ReadingCloseScope, relativeTo document: ReadingDocument) -> [ReadingDocument] {
        guard let index = documents.firstIndex(of: document) else { return [] }
        switch scope {
        case .all: return documents
        case .others: return documents.filter { $0 != document }
        case .right: return Array(documents.dropFirst(index + 1))
        case .left: return Array(documents.prefix(index))
        }
    }

    @discardableResult
    mutating func close(_ scope: ReadingCloseScope, relativeTo document: ReadingDocument) -> Bool {
        remove(documentsToClose(scope, relativeTo: document))
    }

    /// The insertion slot is measured before removal, including both end slots.
    @discardableResult
    mutating func move(_ document: ReadingDocument, to insertionIndex: Int) -> Bool {
        guard (0...documents.count).contains(insertionIndex), let source = documents.firstIndex(of: document) else { return false }
        let destination = insertionIndex > source ? insertionIndex - 1 : insertionIndex
        guard destination != source else { return false }
        documents.remove(at: source)
        documents.insert(document, at: destination)
        return true
    }

    private mutating func remove(_ targets: [ReadingDocument]) -> Bool {
        let previous = documents
        let oldActive = activeDocument
        let ids = Set(targets.map(\.id))
        documents.removeAll { ids.contains($0.id) }
        if let oldActive, ids.contains(oldActive.id), let index = previous.firstIndex(of: oldActive) {
            activeDocument = previous.dropFirst(index + 1).first { !ids.contains($0.id) }
                ?? previous.prefix(index).last { !ids.contains($0.id) }
        }
        return oldActive != activeDocument
    }

    mutating func restore(documents: [ReadingDocument], active: ReadingDocument?) {
        var seen = Set<ReadingDocument>()
        self.documents = documents.filter { seen.insert($0).inserted }
        activeDocument = active.flatMap { self.documents.contains($0) ? $0 : nil } ?? self.documents.first
    }

    mutating func reset() { documents = []; activeDocument = nil }

    mutating func renamePaths(_ renames: [String: String]) {
        func renamed(_ document: ReadingDocument) -> ReadingDocument {
            ReadingDocument(path: renames[document.path] ?? document.path, comparison: document.comparison)
        }
        documents = documents.map(renamed).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        activeDocument = activeDocument.map(renamed)
    }
}
