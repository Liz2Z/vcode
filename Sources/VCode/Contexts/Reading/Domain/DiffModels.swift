import Foundation

enum LineKind: Equatable {
    case unchanged, added, removed, placeholder
}

struct CodeLine: Equatable {
    let number: Int?
    let text: String
    let kind: LineKind

    init(number: Int?, text: String, kind: LineKind) {
        self.number = number
        self.text = text
        self.kind = kind
    }
}

struct DiffRow: Equatable {
    let left: CodeLine
    let right: CodeLine
}
