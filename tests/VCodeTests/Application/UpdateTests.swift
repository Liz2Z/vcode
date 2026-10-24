import AppKit
import XCTest
@testable import VCode

final class UpdateTests: XCTestCase {
    private func bundle(feed: String, key: String) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("VCode.app")
        let contents = root.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let info: [String: Any] = ["CFBundleIdentifier": "dev.vcode.update-tests." + UUID().uuidString,
                                  "CFBundleVersion": "1", "CFBundleName": "VCode",
                                  "SUFeedURL": feed, "SUPublicEDKey": key]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: root))
    }

    func testInvalidUpdateConfigurationCannotStartOrEnableUpdateActions() throws {
        _ = NSApplication.shared
        for (feed, key) in [("http://example.com/appcast.xml", Data(repeating: 1, count: 32).base64EncodedString()),
                            ("https://example.com/appcast.xml", "not a signing key")] {
            let controller = UpdateController(bundle: try bundle(feed: feed, key: key))
            var errors: [String] = []
            controller.onError = { errors.append($0) }
            let menu = NSMenu()
            controller.addMenuItems(to: menu)
            controller.start()
            XCTAssertNil(controller.updater)
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(menu.items.allSatisfy { !controller.validateMenuItem($0) && !$0.isEnabled })
        }
    }

    func testCommandLineExecutableDoesNotInitializeAnUpdater() {
        _ = NSApplication.shared
        let controller = UpdateController()
        controller.start()
        XCTAssertNil(controller.updater)
    }
}
