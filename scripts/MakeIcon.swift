import AppKit

guard [2, 3].contains(CommandLine.arguments.count) else {
    fputs("Usage: swift scripts/MakeIcon.swift <output.icns> [icon-library-directory]\n", stderr)
    exit(2)
}

// Package the approved artwork directly so rebuilding cannot restore the old
// icon or diverge from the design assets. No rendering tools are needed.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let flavor = ProcessInfo.processInfo.environment["VCODE_BUILD_FLAVOR"] ?? "preview"
guard ["preview", "release"].contains(flavor) else {
    fputs("VCODE_BUILD_FLAVOR must be preview or release.\n", stderr)
    exit(2)
}
let artwork = flavor == "preview" ? "Resources/Brand/Lightsaber/AppIcon-preview-padded.icns" : "Resources/Brand/AppIcon.icns"
let source = root.appendingPathComponent(artwork)
let data = try Data(contentsOf: source)
guard data.starts(with: Data("icns".utf8)), NSImage(data: data) != nil else {
    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)

if CommandLine.arguments.count == 3 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let library = [
        "origami": "Resources/Brand/AppIcon.icns",
        "lightsaber": "Resources/Brand/Lightsaber/AppIcon-preview-padded.icns",
        "gummy": "Resources/Brand/Gummy/AppIcon.icns",
        "spectrum": "Resources/Brand/Spectrum/AppIcon.icns",
        "clock-colorful": "Resources/Brand/ClockColorful/AppIcon.icns",
        "clock-bauhaus": "Resources/Brand/ClockBauhaus/AppIcon.icns"
    ]
    for (name, path) in library {
        let source = root.appendingPathComponent(path)
        let artwork = try Data(contentsOf: source)
        guard artwork.starts(with: Data("icns".utf8)), NSImage(data: artwork)?.isValid == true else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
        }
        try artwork.write(to: directory.appendingPathComponent(name + ".icns"), options: .atomic)
    }
}
