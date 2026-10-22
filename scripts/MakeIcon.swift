import AppKit

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift scripts/MakeIcon.swift <output.icns>\n", stderr)
    exit(2)
}

// Package the approved artwork directly so rebuilding cannot restore the old
// icon or diverge from the design assets. No rendering tools are needed.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Resources/Brand/AppIcon.icns")
let data = try Data(contentsOf: source)
guard data.starts(with: Data("icns".utf8)), NSImage(data: data) != nil else {
    throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: source.path])
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
