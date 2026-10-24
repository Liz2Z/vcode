import AppKit
import XCTest
@testable import VCode

final class AppearanceTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }
    private func directory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-appearance-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func resolved(_ color: NSColor, _ appearance: NSAppearance) -> NSColor {
        var result: NSColor!
        appearance.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.sRGB)!
            result = NSColor(srgbRed: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: rgb.alphaComponent)
        }
        return result
    }
    private func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB)!
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }
    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testDayAndNightSyntaxAndInterfaceHaveReadableContrastIncludingDiff() throws {
        let source = "export interface Project { name: string; }\nconst project: Project = { name: \"day\", count: 42 };\nfunction greet(value: Project): boolean { return true; } // Comment\nproject.name; greet(project);"
        let storage = NSTextStorage(string: source)
        Syntax.apply(to: storage, path: "main.ts", font: Theme.Code.font())
        var syntax: [NSColor] = []
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let color = value as? NSColor { syntax.append(color) }
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            for background in [Theme.background, Theme.added, Theme.removed] {
                for foreground in syntax + [Theme.text, Theme.muted, Theme.accent, Theme.green, Theme.red] {
                    XCTAssertGreaterThanOrEqual(contrast(resolved(foreground, appearance), resolved(background, appearance)), 4.5)
                }
            }
            XCTAssertGreaterThanOrEqual(Set(syntax.map { resolved($0, appearance).description }).count, 8)
        }
        XCTAssertGreaterThan(luminance(resolved(Theme.background, NSAppearance(named: .aqua)!)), 0.9)
        XCTAssertLessThan(luminance(resolved(Theme.background, NSAppearance(named: .darkAqua)!)), 0.03)
    }

    func testPreferenceUsesConfigDirectoryAndPersistsAllModes() throws {
        let root = directory()
        let xdg = XDGDirectories(environment: ["XDG_CONFIG_HOME": root.path], home: root)
        let store = AppearanceSettings(directory: xdg.config)
        XCTAssertEqual(store.mode, .light)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
        for mode in AppearanceMode.allCases {
            store.save(mode)
            XCTAssertNil(store.persistenceError)
            XCTAssertEqual(AppearanceSettings(directory: xdg.config).mode, mode)
        }
        XCTAssertEqual(store.file, root.appendingPathComponent("vcode/appearance.json"))
        let attributes = try FileManager.default.attributesOfItem(atPath: xdg.config.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCorruptOrUnwritableConfigurationIsReportedAndPreserved() throws {
        let root = directory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("appearance.json")
        let bad = Data("unreadable theme choice".utf8)
        try bad.write(to: file)
        let store = AppearanceSettings(directory: root)
        XCTAssertEqual(store.mode, .light)
        XCTAssertNotNil(store.persistenceError)
        store.save(.dark)
        XCTAssertEqual(try Data(contentsOf: file), bad)
        let blocked = root.appendingPathComponent("blocked")
        try Data("file, not folder".utf8).write(to: blocked)
        let failed = AppearanceSettings(directory: blocked)
        failed.save(.dark)
        XCTAssertNotNil(failed.persistenceError)
        XCTAssertEqual(try String(contentsOf: blocked), "file, not folder")
    }

    func testSystemModeRecolorsLayersWhenEffectiveAppearanceChanges() throws {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; Theme.refreshLayerColors(using: NSApp.effectiveAppearance) }
        let controller = AppearanceController(settings: AppearanceSettings(directory: directory()))
        controller.start(); controller.select(.system)
        XCTAssertNil(NSApp.appearance)
        let view = NSView(); Theme.fill(view, Theme.background)
        for (name, light) in [(NSAppearance.Name.darkAqua, false), (.aqua, true), (.darkAqua, false)] {
            NSApp.appearance = NSAppearance(named: name)
            let color = NSColor(cgColor: try XCTUnwrap(view.layer?.backgroundColor))!
            XCTAssertEqual(luminance(color) > 0.9, light, "Effective appearance observation must refresh CGColor caches")
            XCTAssertEqual(controller.settings.mode, .system)
        }
    }

    func testMenuSwitchRecolorsExistingLayersAndDocumentsWithoutChangingReadingState() throws {
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous; Theme.refreshLayerColors(using: NSApp.effectiveAppearance) }
        let controller = AppearanceController(settings: AppearanceSettings(directory: directory()))
        controller.start()
        let menu = NSMenu(); controller.addMenuItems(to: menu)
        XCTAssertEqual(menu.items.map(\.title), AppearanceMode.allCases.map(\.title))
        let workspace = WorkspaceView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = workspace
        defer { window.close() }
        workspace.editorGroups.setWorkspaceOpen(true)
        let editor = workspace.editor
        let source = (0..<120).map { "export const value\($0) = \"a long line for reading position\";" }.joined(separator: "\n")
        let snapshot = FileSnapshot(path: "main.ts", before: source, after: source, rows: [], message: nil, isBinary: false)
        editor.prepare(path: snapshot.path, diff: false, isGit: true)
        editor.show(snapshot, diff: false, preserveScroll: false)
        workspace.layoutSubtreeIfNeeded()
        editor.right.text.setSelectedRange(NSRange(location: 85, length: 7))
        editor.right.sync(to: NSPoint(x: 0, y: 500))
        window.makeFirstResponder(editor.right.text)
        let storage = try XCTUnwrap(editor.right.text.textStorage)
        let selected = editor.right.text.selectedRange(), position = editor.right.scroll.contentView.bounds.origin
        let rendered = editor.right.text.string
        let geometry = editor.frame
        let button = Theme.actionButton("Selected"); button.isSelected = true
        workspace.addSubview(button)
        let panel = FloatingSurface(); workspace.addSubview(panel)
        for mode in [AppearanceMode.dark, .light, .system, .light] {
            let item = try XCTUnwrap(menu.items.first { $0.representedObject as? String == mode.rawValue })
            controller.selectAppearance(item)
            XCTAssertEqual(menu.items.filter { $0.state == .on }.map(\.title), [mode.title])
            XCTAssertTrue(editor.right.text.textStorage === storage)
            XCTAssertEqual(editor.right.text.string, rendered)
            XCTAssertEqual(editor.right.text.selectedRange(), selected)
            XCTAssertEqual(editor.right.scroll.contentView.bounds.origin, position)
            XCTAssertEqual(editor.frame, geometry)
            XCTAssertTrue(window.firstResponder === editor.right.text)
            let appearance = NSApp.effectiveAppearance
            let actual = try XCTUnwrap(workspace.layer?.backgroundColor).components!
            let expected = resolved(Theme.canvas, appearance).usingColorSpace(.sRGB)!
            XCTAssertEqual(actual[0], expected.redComponent, accuracy: 0.001)
            let fill = try XCTUnwrap(button.layer?.backgroundColor).components!
            let accent = resolved(Theme.accent, appearance).usingColorSpace(.sRGB)!
            XCTAssertEqual(fill[0], accent.redComponent, accuracy: 0.001)
            XCTAssertEqual(fill[3], 0.18, accuracy: 0.001)
            let shadow = try XCTUnwrap(panel.layer?.shadowColor).alpha
            XCTAssertEqual(shadow, Theme.isDark(appearance) ? 0.4 : 0.15, accuracy: 0.001)
        }
        XCTAssertEqual(AppearanceSettings(directory: controller.settings.file.deletingLastPathComponent()).mode, .light)
    }
}
