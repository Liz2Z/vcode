import Foundation

enum AppearanceMode: String, Codable, CaseIterable {
    case light, dark, system
    var title: String {
        switch self {
        case .light: return "Light Theme"
        case .dark: return "Dark Theme"
        case .system: return "Follow System Appearance"
        }
    }
}

final class AppearanceSettings {
    private struct Settings: Codable { let appearance: AppearanceMode }
    let file: URL
    private(set) var mode: AppearanceMode = .light
    private(set) var persistenceError: String?
    private var unreadable = false

    init(directory: URL = XDGDirectories().config) {
        file = directory.appendingPathComponent("appearance.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { mode = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file)).appearance }
        catch { unreadable = true; persistenceError = "Could not read appearance settings: " + error.localizedDescription }
    }

    func save(_ mode: AppearanceMode) {
        self.mode = mode
        guard !unreadable else { return }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Settings(appearance: mode)).write(to: file, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Could not save appearance settings: " + error.localizedDescription }
    }
}
