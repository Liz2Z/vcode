import Foundation

struct SourceContent {
    let data: Data
    let message: String?
    var isBinary: Bool { data.contains(0) || String(data: data, encoding: .utf8) == nil }
}
