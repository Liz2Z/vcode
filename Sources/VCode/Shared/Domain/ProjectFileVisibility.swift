// Project browsing and actions share this policy independently of Git ignore rules.
enum ProjectFileVisibility {
    private static let metadataNames: Set<String> = [
        ".git", ".ds_store", ".appledouble", ".lsoverride", ".spotlight-v100",
        ".trashes", ".fseventsd", ".temporaryitems", ".volumeicon.icns", "__macosx"
    ]

    static func isVisible(_ path: String) -> Bool {
        !path.split(separator: "/").contains { component in
            let name = component.lowercased()
            return metadataNames.contains(name) || name.hasPrefix("._")
        }
    }
}
