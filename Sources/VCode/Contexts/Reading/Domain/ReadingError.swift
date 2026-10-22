import Foundation

enum ReadingError: LocalizedError {
    case invalidPatch

    var errorDescription: String? { "The file changed while its diff was loading. Refresh to try again." }
}
