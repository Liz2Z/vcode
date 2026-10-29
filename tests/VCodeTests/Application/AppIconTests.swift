import AppKit
import XCTest
@testable import VCode

final class AppIconTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-icons-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func resources(flavor: String = "preview") throws -> URL {
        let root = try directory()
        let library = root.appendingPathComponent("AppIcons")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), diagnostics = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["scripts/MakeIcon.swift", root.appendingPathComponent("AppIcon.icns").path, library.path]
        process.currentDirectoryURL = repo
        process.environment = ProcessInfo.processInfo.environment.merging(["VCODE_BUILD_FLAVOR": flavor]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostics
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: diagnostics.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            XCTFail(message)
            throw CocoaError(.fileReadCorruptFile)
        }
        let defaultStyle: AppIconStyle = flavor == "preview" ? .lightsaber : .origami
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: library.path)),
                       Set(AppIconStyle.allCases.filter { $0 != defaultStyle }.map { $0.rawValue + ".png" }))
        for style in AppIconStyle.allCases where style != defaultStyle {
            let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: library.appendingPathComponent(style.rawValue + ".png"))))
            XCTAssertEqual(image.pixelsWide, 1024)
            XCTAssertEqual(image.pixelsHigh, 1024)
        }
        return root
    }

    func testMenuChoicesApplyTheirRealArtworkAndPersistAcrossLaunches() throws {
        let resources = try resources(), config = try directory()
        let releaseResources = try self.resources(flavor: "release")
        var images: [NSImage] = []
        let settings = AppIconSettings(directory: config)
        let controller = AppIconController(settings: settings, resourceDirectory: resources, defaultStyle: .lightsaber) { images.append($0) }
        controller.start()
        XCTAssertEqual(controller.currentStyle, .lightsaber)
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.file.path), "Launching must not pin the build default into preferences")
        let menu = NSMenu()
        controller.addMenu(to: menu)
        let options = try XCTUnwrap(menu.items.first?.submenu)
        let choices = options.items.filter { $0.representedObject is String }
        XCTAssertEqual(choices.map(\.title), ["Origami", "Lightsaber", "Gummy", "Spectrum", "Clock Colorful", "Clock Bauhaus"])
        XCTAssertTrue(choices.allSatisfy { $0.image != nil && $0.isEnabled })
        var data = Set<Data>()
        for (index, style) in AppIconStyle.allCases.enumerated() {
            options.performActionForItem(at: index)
            XCTAssertEqual(controller.currentStyle, style)
            XCTAssertEqual(options.items.filter { $0.state == .on }.map(\.title), [style.title])
            let image = try XCTUnwrap(controller.currentImage)
            XCTAssertTrue(image.isValid)
            XCTAssertGreaterThanOrEqual(image.representations.map(\.pixelsWide).max() ?? 0, 1024)
            XCTAssertEqual(choices[index].image?.size, NSSize(width: 24, height: 24), "Menu thumbnail sizing must not resize the application icon")
            data.insert(try XCTUnwrap(image.tiffRepresentation))
            let relaunched = AppIconController(settings: AppIconSettings(directory: config), resourceDirectory: releaseResources, defaultStyle: .origami) { _ in }
            relaunched.start()
            XCTAssertEqual(relaunched.currentStyle, style, "A saved choice overrides either build flavor")
        }
        XCTAssertEqual(data.count, choices.count, "Every choice must have its own actual artwork")
        XCTAssertEqual(images.count, choices.count + 1)
        XCTAssertEqual(settings.file, config.appendingPathComponent("app-icon.json"))
    }

    func testResetResumesFollowingTheCurrentBuildDefault() throws {
        let resources = try resources(), config = try directory()
        let controller = AppIconController(settings: AppIconSettings(directory: config), resourceDirectory: resources, defaultStyle: .lightsaber) { _ in }
        controller.start()
        let menu = NSMenu(); controller.addMenu(to: menu)
        let options = try XCTUnwrap(menu.items.first?.submenu)
        let reset = try XCTUnwrap(options.items.last)
        XCTAssertFalse(reset.isEnabled)
        controller.select(.gummy)
        XCTAssertTrue(reset.isEnabled)
        options.performActionForItem(at: options.items.count - 1)
        XCTAssertEqual(controller.currentStyle, .lightsaber)
        XCTAssertNil(controller.settings.selection)
        XCTAssertFalse(reset.isEnabled)
        let release = AppIconController(settings: AppIconSettings(directory: config), resourceDirectory: try self.resources(flavor: "release"), defaultStyle: .origami) { _ in }
        release.start()
        XCTAssertEqual(release.currentStyle, .origami)
    }

    func testMissingArtworkAndFailedWritesKeepTheWorkingIconAndChoice() throws {
        let resources = try resources(flavor: "release"), config = try directory()
        let controller = AppIconController(settings: AppIconSettings(directory: config), resourceDirectory: resources, defaultStyle: .origami) { _ in }
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.start()
        controller.select(.gummy)
        let workingImage = controller.currentImage
        try FileManager.default.removeItem(at: resources.appendingPathComponent("AppIcons/spectrum.png"))
        controller.select(.spectrum)
        XCTAssertEqual(controller.currentStyle, .gummy)
        XCTAssertTrue(controller.currentImage === workingImage)
        XCTAssertEqual(AppIconSettings(directory: config).selection, .gummy)
        XCTAssertEqual(errors.count, 1)
        try FileManager.default.removeItem(at: controller.settings.file)
        try FileManager.default.createDirectory(at: controller.settings.file, withIntermediateDirectories: true)
        controller.select(.lightsaber)
        XCTAssertEqual(controller.currentStyle, .gummy)
        XCTAssertEqual(controller.settings.selection, .gummy)
        XCTAssertTrue(controller.currentImage === workingImage)
        XCTAssertEqual(errors.count, 2)
    }

    func testCorruptSettingsFallBackWithoutOverwritingAndCanBeReplacedByExplicitChoice() throws {
        let config = try directory(), resources = try resources()
        let file = config.appendingPathComponent("app-icon.json")
        let invalid = Data("{\"icon\":\"no-longer-available\"}".utf8)
        try invalid.write(to: file)
        let controller = AppIconController(settings: AppIconSettings(directory: config), resourceDirectory: resources, defaultStyle: .lightsaber) { _ in }
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.start()
        XCTAssertEqual(controller.currentStyle, .lightsaber)
        XCTAssertEqual(try Data(contentsOf: file), invalid)
        XCTAssertEqual(errors.count, 1)
        controller.select(.spectrum)
        XCTAssertNil(controller.settings.persistenceError)
        XCTAssertEqual(AppIconSettings(directory: config).selection, .spectrum)
    }
}
