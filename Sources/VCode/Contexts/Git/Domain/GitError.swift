import Foundation

enum GitError: LocalizedError {
    case command(String)
    case contentTooLarge

    var errorDescription: String? {
        switch self {
        case .command(let message): return message.trimmingCharacters(in: .whitespacesAndNewlines)
        case .contentTooLarge: return "Git file exceeds the requested preview limit."
        }
    }
}
