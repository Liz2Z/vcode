import Foundation

struct ProjectSearchQuery: Equatable {
    var text: String
    var caseSensitive = false
    var wholeWord = false
    var regularExpression = false
    var excludedFolders = ""
}

struct ProjectSearchMatch: Equatable {
    let path: String
    let line: Int // zero-based, with UTF-16 ranges for the native reader
    let text: String
    let ranges: [NSRange]
    var character: Int { ranges.first?.location ?? 0 }
}

struct ProjectSearchResults {
    var matches: [ProjectSearchMatch] = []
    var limited = false
    var skippedFiles = 0
    var warning: String?
}

enum ProjectSearchError: LocalizedError {
    case unavailable, cancelled, failed(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Search engine unavailable. Rebuild the app with ripgrep installed."
        case .cancelled: return "Search cancelled"
        case .failed(let message): return message
        }
    }
}
