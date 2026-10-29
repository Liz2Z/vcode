import AppKit

guard [2, 3].contains(CommandLine.arguments.count) else {
    fputs("Usage: swift scripts/MakeIcon.swift <output.icns> [icon-library-directory]\n", stderr)
    exit(2)
}

// Preserve the approved pixels. Finder gets one complete ICNS; runtime choices
// use its existing 1024px PNG representation without re-encoding or resampling.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let flavor = ProcessInfo.processInfo.environment["VCODE_BUILD_FLAVOR"] ?? "preview"
guard ["preview", "release"].contains(flavor) else {
    fputs("VCODE_BUILD_FLAVOR must be preview or release.\n", stderr)
    exit(2)
}
let library = [
    "origami": "Resources/Brand/AppIcon.icns",
    "lightsaber": "Resources/Brand/Lightsaber/AppIcon-preview-padded.icns",
    "gummy": "Resources/Brand/Gummy/AppIcon.icns",
    "spectrum": "Resources/Brand/Spectrum/AppIcon.icns",
    "clock-colorful": "Resources/Brand/ClockColorful/AppIcon.icns",
    "clock-bauhaus": "Resources/Brand/ClockBauhaus/AppIcon.icns"
]
let defaultName = flavor == "preview" ? "lightsaber" : "origami"
let source = root.appendingPathComponent(library[defaultName]!)
let data = try Data(contentsOf: source)
guard data.starts(with: Data("icns".utf8)), NSImage(data: data) != nil else {
    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)

if CommandLine.arguments.count == 3 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    var alternatives: [String: Data] = [:]
    for (name, path) in library where name != defaultName {
        alternatives[name] = try largestPNG(in: root.appendingPathComponent(path))
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (name, png) in alternatives {
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
    // Also remove the old layout when packaging into an existing output directory.
    for name in library.keys {
        let obsolete = directory.appendingPathComponent(name + ".icns")
        if FileManager.default.fileExists(atPath: obsolete.path) { try FileManager.default.removeItem(at: obsolete) }
        if name == defaultName {
            let duplicate = directory.appendingPathComponent(name + ".png")
            if FileManager.default.fileExists(atPath: duplicate.path) { try FileManager.default.removeItem(at: duplicate) }
        }
    }
}

func largestPNG(in source: URL) throws -> Data {
    let data = try Data(contentsOf: source)
    func corrupt() -> CocoaError { CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path]) }
    guard data.count >= 8, data.starts(with: Data("icns".utf8)) else { throw corrupt() }
    var offset = 8
    while offset <= data.count - 8 {
        let length = data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
        guard length >= 8, length <= data.count - offset else { throw corrupt() }
        if data[offset..<(offset + 4)].elementsEqual("ic10".utf8) {
            let png = Data(data[(offset + 8)..<(offset + length)])
            guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
                  let image = NSBitmapImageRep(data: png), image.pixelsWide == 1024, image.pixelsHigh == 1024 else { throw corrupt() }
            return png
        }
        offset += length
    }
    throw corrupt()
}
