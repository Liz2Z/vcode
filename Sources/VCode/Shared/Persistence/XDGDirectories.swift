import Foundation

// XDG Base Directory Specification 0.8. Relative environment values are invalid.
struct XDGDirectories {
    let config: URL
    let data: URL
    let state: URL
    let cache: URL

    init(environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        func directory(_ key: String, fallback: String) -> URL {
            let base: URL
            if let value = environment[key], value.hasPrefix("/") { base = URL(fileURLWithPath: value, isDirectory: true) }
            else { base = home.appendingPathComponent(fallback, isDirectory: true) }
            return base.appendingPathComponent("vcode", isDirectory: true).standardizedFileURL
        }
        config = directory("XDG_CONFIG_HOME", fallback: ".config")
        data = directory("XDG_DATA_HOME", fallback: ".local/share")
        state = directory("XDG_STATE_HOME", fallback: ".local/state")
        cache = directory("XDG_CACHE_HOME", fallback: ".cache")
    }
}
