import Foundation

enum InspectionKind: String {
    case hover, definition, references, documentHighlight
}

enum LanguageInspection {
    case hover(String)
    case locations([CodeLocation])
    case highlights([SymbolOccurrence])
}

struct SymbolOccurrence: Equatable {
    let startLine: Int
    let startCharacter: Int
    let endLine: Int
    let endCharacter: Int
}
