import Foundation

enum FileAccessError: LocalizedError {
    case unavailableFolder
    case invalidPath
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unavailableFolder: return "Choose an existing folder."
        case .invalidPath: return "This file is outside the opened folder."
        case .tooLarge: return "This file is larger than the 4 MB preview limit."
        }
    }
}
