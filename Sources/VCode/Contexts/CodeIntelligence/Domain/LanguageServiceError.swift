import Foundation

enum LanguageServiceError: LocalizedError {
    case connection(String)
    var errorDescription: String? {
        switch self { case .connection(let message): return message }
    }
}
