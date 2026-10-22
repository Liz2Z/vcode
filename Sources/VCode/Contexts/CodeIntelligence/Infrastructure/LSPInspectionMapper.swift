import Foundation

enum LSPInspectionMapper {
    static func decode(_ value: Any, kind: InspectionKind) throws -> LanguageInspection {
        if kind == .documentHighlight {
            if value is NSNull { return .highlights([]) }
            guard let objects = value as? [[String: Any]] else { throw malformed() }
            return .highlights(objects.compactMap { object in
                guard let range = object["range"] as? [String: Any],
                      let start = range["start"] as? [String: Any], let end = range["end"] as? [String: Any],
                      let line = start["line"] as? Int, let character = start["character"] as? Int,
                      let endLine = end["line"] as? Int, let endCharacter = end["character"] as? Int,
                      line >= 0, character >= 0, endLine >= line, endCharacter >= 0,
                      endLine > line || endCharacter > character else { return nil }
                return SymbolOccurrence(startLine: line, startCharacter: character, endLine: endLine, endCharacter: endCharacter)
            })
        }
        if kind == .hover {
            if value is NSNull { return .hover("") }
            guard let object = value as? [String: Any], let contents = object["contents"] else { throw malformed() }
            return .hover(try hoverMarkdown(contents))
        }
        if value is NSNull { return .locations([]) }
        let objects: [[String: Any]]
        if let list = value as? [[String: Any]] { objects = list }
        else if let object = value as? [String: Any] { objects = [object] }
        else { throw malformed() }
        let locations = objects.compactMap { object -> CodeLocation? in
            guard let uri = (object["uri"] ?? object["targetUri"]) as? String,
                  let url = URL(string: uri), url.isFileURL,
                  let range = (object["targetSelectionRange"] ?? object["range"]) as? [String: Any],
                  let start = range["start"] as? [String: Any],
                  let line = start["line"] as? Int, line >= 0,
                  let character = start["character"] as? Int, character >= 0 else { return nil }
            return CodeLocation(url: url, line: line, character: character)
        }
        return .locations(locations)
    }

    private static func hoverMarkdown(_ value: Any) throws -> String {
        if let string = value as? String { return string }
        if let array = value as? [Any] { return try array.map(hoverMarkdown).joined(separator: "\n\n") }
        if let object = value as? [String: Any], let string = object["value"] as? String {
            if let language = object["language"] as? String { return "```" + language + "\n" + string + "\n```" }
            return string
        }
        throw malformed()
    }

    private static func malformed() -> LanguageServiceError { .connection("TypeScript returned an invalid inspection result.") }
}
