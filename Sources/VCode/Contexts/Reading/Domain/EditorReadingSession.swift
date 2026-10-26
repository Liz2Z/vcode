import Foundation

/// Only open documents and their content anchors, never a cached copy of a file.
struct EditorReadingSession: Codable, Equatable {
    var documents: [ReadingDocument]
    var activeDocument: ReadingDocument?
    var positions: [ReadingLocation]
    var markdownSourcePaths: [String]

    var validated: EditorReadingSession {
        var seen = Set<ReadingDocument>()
        let documents = documents.filter { Self.validPath($0.path) && (!$0.isDraft || $0.comparison == nil) && seen.insert($0).inserted }
        let active = activeDocument.flatMap { documents.contains($0) ? $0 : nil } ?? documents.first
        return EditorReadingSession(documents: documents, activeDocument: active,
            positions: positions.filter { documents.contains($0.document) && Self.validPosition($0) },
            markdownSourcePaths: markdownSourcePaths.filter { Self.validPath($0) })
    }

    private static func validPosition(_ location: ReadingLocation) -> Bool {
        func anchor(_ value: ReadingTextAnchor) -> Bool { value.line >= 0 && value.character >= 0 }
        func pane(_ value: PaneReadingPosition) -> Bool {
            anchor(value.start) && anchor(value.end) && anchor(value.top) && value.verticalOffset.isFinite
                && value.horizontalOffset.isFinite
        }
        guard pane(location.left), pane(location.right) else { return false }
        guard let markdown = location.markdown else { return true }
        return markdown.selection.location >= 0 && markdown.selection.length >= 0
            && markdown.x.isFinite && markdown.y.isFinite && markdown.x >= 0 && markdown.y >= 0
            && markdown.verticalOffset.isFinite && (markdown.top.map(anchor) ?? true)
    }

    private static func validPath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0") && !path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }
}
