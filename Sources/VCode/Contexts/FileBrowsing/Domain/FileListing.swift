import Foundation

struct FileListing {
    var paths: [String]
    var identities: [String: AnyHashable]
    var directories: [String] = []
    var deferredDirectories: Set<String> = []
    var searchablePaths: [String] = []
}
