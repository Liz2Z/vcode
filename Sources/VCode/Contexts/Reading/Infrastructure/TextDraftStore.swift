import Foundation

/// Draft contents are user data; reading sessions keep only their UUIDs in STATE_HOME.
struct TextDraft: Codable, Equatable {
    var text = ""
    var destination: URL?
    var savedText: String?
    var needsSave: Bool { destination == nil ? !text.isEmpty : text != savedText }
}

final class TextDraftStore {
    let directory: URL
    init(directory: URL = XDGDirectories().data.appendingPathComponent("drafts", isDirectory: true)) {
        self.directory = directory
    }
    func load(_ id: UUID) throws -> TextDraft {
        try JSONDecoder().decode(TextDraft.self, from: Data(contentsOf: file(id)))
    }
    func save(_ draft: TextDraft, id: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(draft).write(to: file(id), options: .atomic)
    }
    func export(_ draft: TextDraft, to url: URL) throws -> TextDraft {
        // Re-saving must not silently overwrite an externally modified file.
        if url == draft.destination, let saved = draft.savedText,
           try String(contentsOf: url, encoding: .utf8) != saved {
            throw NSError(domain: "VCode.Draft", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The saved file changed outside VCode. Use Save As to keep both versions."])
        }
        try Data(draft.text.utf8).write(to: url, options: .atomic)
        var saved = draft
        saved.destination = url
        saved.savedText = draft.text
        return saved
    }
    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}
