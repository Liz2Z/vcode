import Foundation

struct ReadingDocument: Codable, Hashable {
    let path: String
    let comparison: GitComparison?
    var draftID: UUID? = nil
    var isDraft: Bool { draftID != nil }
    var id: String { draftID.map { "draft\0" + $0.uuidString } ?? ((comparison?.rawValue ?? "source") + "\0" + path) }
}

enum ReadingCloseScope: CaseIterable {
    case all, others, right, left
}

struct ReaderSession {
    private(set) var documents: [ReadingDocument] = []
    private(set) var activeDocument: ReadingDocument?
    // Activation order is independent of the visible tab order, as in VS Code.
    private var recentDocuments: [ReadingDocument] = []
    var paths: [String] { documents.map(\.path) }
    var activePath: String? { activeDocument.flatMap { $0.isDraft ? nil : $0.path } }

    mutating func open(_ path: String, comparison: GitComparison? = nil) {
        let document = ReadingDocument(path: path, comparison: comparison)
        open(document)
    }

    mutating func open(_ document: ReadingDocument) {
        if !documents.contains(document) { documents.append(document) }
        activeDocument = document
        recentDocuments.removeAll { $0 == document }
        recentDocuments.insert(document, at: 0)
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

    mutating func close(_ documents: [ReadingDocument]) -> Bool { remove(documents) }

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
        let oldActive = activeDocument
        let ids = Set(targets.map(\.id))
        documents.removeAll { ids.contains($0.id) }
        recentDocuments.removeAll { ids.contains($0.id) }
        if let oldActive, ids.contains(oldActive.id) {
            activeDocument = recentDocuments.first
        }
        return oldActive != activeDocument
    }

    mutating func restore(documents: [ReadingDocument], active: ReadingDocument?) {
        var seen = Set<ReadingDocument>()
        self.documents = documents.filter { seen.insert($0).inserted }
        activeDocument = active.flatMap { self.documents.contains($0) ? $0 : nil } ?? self.documents.first
        recentDocuments = self.documents
        if let activeDocument {
            recentDocuments.removeAll { $0 == activeDocument }
            recentDocuments.insert(activeDocument, at: 0)
        }
    }

    mutating func reset() { documents = []; activeDocument = nil; recentDocuments = [] }

    mutating func renamePaths(_ renames: [String: String]) {
        func renamed(_ document: ReadingDocument) -> ReadingDocument {
            document.isDraft ? document : ReadingDocument(path: renames[document.path] ?? document.path, comparison: document.comparison)
        }
        documents = documents.map(renamed).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        activeDocument = activeDocument.map(renamed)
        recentDocuments = recentDocuments.map(renamed).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}
