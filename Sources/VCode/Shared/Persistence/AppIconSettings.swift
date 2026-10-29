import Foundation

enum AppIconStyle: String, Codable, CaseIterable {
    case origami, lightsaber, gummy, spectrum

    var title: String {
        switch self {
        case .origami: return "Origami"
        case .lightsaber: return "Lightsaber"
        case .gummy: return "Gummy"
        case .spectrum: return "Spectrum"
        }
    }
}

final class AppIconSettings {
    private struct Settings: Codable { let icon: AppIconStyle? }
    let file: URL
    private(set) var selection: AppIconStyle?
    private(set) var persistenceError: String?

    init(directory: URL = XDGDirectories().config) {
        file = directory.appendingPathComponent("app-icon.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { selection = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file)).icon }
        catch { persistenceError = "Could not read app icon settings: " + error.localizedDescription }
    }

    func save(_ icon: AppIconStyle?) throws {
        // A deliberate menu selection can replace an invalid preference, while
        // merely launching the application never overwrites it.
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Settings(icon: icon)).write(to: file, options: .atomic)
        selection = icon
        persistenceError = nil
    }
}
