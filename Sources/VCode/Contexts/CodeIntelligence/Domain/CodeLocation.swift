import Foundation

struct CodeLocation: Hashable {
    let url: URL
    let line: Int
    let character: Int
}

