import Foundation
import XCTest
@testable import VCode

extension XCTestCase {
    func isolatedHistoryStore() -> WorkspaceHistoryStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-xdg-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return WorkspaceHistoryStore(directory: directory, legacyDefaults: nil)
    }
}

final class XDGStorageTests: XCTestCase {
    func testDefaultsAbsoluteOverridesAndInvalidRelativeValues() {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        let defaults = XDGDirectories(environment: [:], home: home)
        XCTAssertEqual(defaults.config.path, "/tmp/test-home/.config/vcode")
        XCTAssertEqual(defaults.data.path, "/tmp/test-home/.local/share/vcode")
        XCTAssertEqual(defaults.state.path, "/tmp/test-home/.local/state/vcode")
        XCTAssertEqual(defaults.cache.path, "/tmp/test-home/.cache/vcode")
        let custom = XDGDirectories(environment: ["XDG_STATE_HOME": "/tmp/custom-state", "XDG_CONFIG_HOME": "relative", "XDG_DATA_HOME": "", "XDG_CACHE_HOME": "~/cache"], home: home)
        XCTAssertEqual(custom.state.path, "/tmp/custom-state/vcode")
        XCTAssertEqual(custom.config, defaults.config)
        XCTAssertEqual(custom.data, defaults.data)
        XCTAssertEqual(custom.cache, defaults.cache)
    }

    func testDiskPersistenceIncludesLastWorkspaceAndWindowAndCreatesPrivateDirectory() throws {
        let store = isolatedHistoryStore()
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        store.record(WorkspaceState(root: root, files: [], git: nil))
        let frame = WindowPlacement(x: 30, y: 40, width: 1100, height: 700)
        store.saveWindow(frame)
        XCTAssertNil(store.persistenceError)
        let restored = WorkspaceHistoryStore(directory: store.file.deletingLastPathComponent(), legacyDefaults: nil)
        XCTAssertEqual(restored.lastFolder, root)
        XCTAssertEqual(restored.windowPlacement, frame)
        XCTAssertEqual(restored.entries, store.entries)
        let mode = try FileManager.default.attributesOfItem(atPath: store.file.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testLegacyMigrationAndExistingXDGStateTakesPrecedence() throws {
        let name = "dev.vcode.migration-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = isolatedHistoryStore().file.deletingLastPathComponent()
        let root = URL(fileURLWithPath: "/tmp/old-project", isDirectory: true)
        let entry = RecentWorkspace(state: WorkspaceState(root: root, files: [], git: nil), openedAt: Date())
        defaults.set(try JSONEncoder().encode([entry]), forKey: "recentWorkspaces.v1")
        defaults.set(root.path, forKey: "lastFolder")
        defaults.set("10 20 1100 700 0 0 2000 1000 ", forKey: "NSWindow Frame VCodeWorkspace")
        let migrated = WorkspaceHistoryStore(directory: directory, legacyDefaults: defaults)
        XCTAssertEqual(migrated.entries, [entry])
        XCTAssertEqual(migrated.lastFolder, root)
        XCTAssertEqual(migrated.windowPlacement?.width, 1100)
        XCTAssertNil(defaults.string(forKey: "lastFolder"))
        defaults.set("/tmp/older-value", forKey: "lastFolder")
        XCTAssertEqual(WorkspaceHistoryStore(directory: directory, legacyDefaults: defaults).lastFolder, root)
    }

    func testFailedMigrationKeepsLegacyAndCorruptFileIsNotOverwritten() throws {
        let name = "dev.vcode.failed-migration-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = isolatedHistoryStore().file.deletingLastPathComponent()
        try Data("not a directory".utf8).write(to: directory)
        defaults.set("/tmp/old", forKey: "lastFolder")
        let failed = WorkspaceHistoryStore(directory: directory, legacyDefaults: defaults)
        XCTAssertNotNil(failed.persistenceError)
        XCTAssertEqual(defaults.string(forKey: "lastFolder"), "/tmp/old")
        let store = isolatedHistoryStore()
        try FileManager.default.createDirectory(at: store.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("invalid existing state".utf8)
        try corrupt.write(to: store.file)
        let blocked = WorkspaceHistoryStore(directory: store.file.deletingLastPathComponent(), legacyDefaults: nil)
        XCTAssertNotNil(blocked.persistenceError)
        blocked.record(WorkspaceState(root: URL(fileURLWithPath: "/tmp/new"), files: [], git: nil))
        XCTAssertEqual(try Data(contentsOf: store.file), corrupt)
    }
}
