import AppKit
import XCTest
@testable import VCode

final class WorkspaceSwitchTests: XCTestCase {
    func testBranchAndWorktreeSwitchRefreshContentAndRejectOldReads() throws {
        _ = NSApplication.shared
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-switch-" + UUID().uuidString)
        let primary = base.appendingPathComponent("primary")
        let linked = base.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: primary.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = primary.appendingPathComponent("src/main.ts")
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", primary.path] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "VCode"]); try git(["config", "user.email", "test@localhost"])
        try git(["config", "commit.gpgsign", "false"])
        try "export const branch = 'main';\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try git(["worktree", "add", "-qb", "linked", linked.path])
        try git(["switch", "-qc", "feature"])
        try "export const branch = 'feature';\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "feature"]); try git(["switch", "-q", "main"])

        let session = WorkspaceSession()
        let opened = expectation(description: "session opens")
        session.onOpen = { _ in opened.fulfill() }
        session.open(primary)
        wait(for: [opened], timeout: 10)
        session.onOpen = nil
        var deliveredOldRead = false
        session.read("src/main.ts", diff: true) { _ in deliveredOldRead = true }
        let switched = expectation(description: "session switches branch")
        session.activate(.branch("feature")) { result in
            XCTAssertEqual(try? result.get().branch, "feature")
            switched.fulfill()
        }
        wait(for: [switched], timeout: 10)
        XCTAssertFalse(deliveredOldRead)
        session.close()
        try git(["switch", "-q", "main"])

        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(primary)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.header.branchButton.title == "main" }, object: nil)], timeout: 10)
        controller.openFile("src/main.ts", diff: false)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.editor.right.text.string.contains("'main'") }, object: nil)], timeout: 10)
        let firstSwitch = expectation(description: "controller switches branch")
        controller.activate(.branch("feature")) { result in
            XCTAssertEqual(try? result.get().branch, "feature")
            firstSwitch.fulfill()
        }
        wait(for: [firstSwitch], timeout: 10)
        XCTAssertEqual(workspace.editor.activePath, "src/main.ts")
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.editor.right.text.string.contains("'feature'") }, object: nil)], timeout: 10)
        XCTAssertTrue(workspace.editor.left.text.string.isEmpty)
        XCTAssertTrue(workspace.editor.welcome.isHidden)
        XCTAssertEqual(workspace.explorer.outline.numberOfRows, 1)
        controller.openFile("src/main.ts", diff: true)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.editor.right.text.string.contains("'feature'") }, object: nil)], timeout: 10)
        try "export const branch = 'local retained';\n".write(to: file, atomically: true, encoding: .utf8)
        let refused = expectation(description: "unsafe checkout refuses to overwrite")
        controller.activate(.branch("main")) { result in
            if case .success = result { XCTFail("Must preserve local edit") }
            refused.fulfill()
        }
        wait(for: [refused], timeout: 10)
        XCTAssertEqual(workspace.editor.activePath, "src/main.ts")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "export const branch = 'local retained';\n")
        let nextWorktree = expectation(description: "open occupied worktree")
        controller.activate(.branch("linked")) { result in
            XCTAssertEqual(try? result.get().root.path, linked.resolvingSymlinksInPath().path)
            nextWorktree.fulfill()
        }
        wait(for: [nextWorktree], timeout: 10)
        XCTAssertEqual(workspace.header.branchButton.title, "linked")
        XCTAssertNil(workspace.editor.activePath)
        XCTAssertEqual(workspace.explorer.outline.numberOfRows, 1)
        controller.openFile("src/main.ts", diff: true)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.editor.right.text.string.contains("'main'") }, object: nil)], timeout: 10)
    }

    func testRepeatedBranchSwitchAndResizePreserveSplitSourceAndDiff() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-branch-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("main.ts")
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "core.hooksPath=/dev/null"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(args)")
        }
        func waitUntil(_ condition: @escaping () -> Bool) {
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: 10)
        }
        let body = (0..<160).map { "// line \($0) " + String(repeating: "long content ", count: 16) }.joined(separator: "\n")
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "VCode"]); try git(["config", "user.email", "test@localhost"])
        try git(["config", "commit.gpgsign", "false"])
        try ("export const branch = 'main';\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."]); try git(["commit", "-qm", "main"])
        try git(["switch", "-qc", "feature"])
        try ("export const branch = 'feature';\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try git(["commit", "-qam", "feature"]); try git(["switch", "-q", "main"])
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        waitUntil { workspace.header.branchButton.title == "main" }
        controller.openFile("main.ts", diff: false)
        waitUntil { workspace.editor.currentSource?.contains("'main'") == true }
        let source = workspace.editor
        controller.splitEditorRight()
        controller.openFile("main.ts", diff: true)
        let diff = workspace.editor
        waitUntil { diff.showingDiff && diff.right.text.string.contains("'main'") }
        source.right.sync(to: NSPoint(x: 100, y: 500))
        diff.left.sync(to: NSPoint(x: 100, y: 600))
        diff.right.sync(to: NSPoint(x: 100, y: 600))
        for (index, branch) in ["feature", "main", "feature", "main"].enumerated() {
            window.setContentSize(NSSize(width: index.isMultiple(of: 2) ? 920 : 1360, height: index.isMultiple(of: 2) ? 580 : 700))
            workspace.layoutSubtreeIfNeeded()
            let switched = expectation(description: "switch \(index)")
            controller.activate(.branch(branch)) { result in
                XCTAssertEqual(try? result.get().branch, branch)
                switched.fulfill()
            }
            wait(for: [switched], timeout: 10)
            waitUntil { source.currentSource?.contains("'\(branch)'") == true && diff.right.text.string.contains("'\(branch)'") }
            workspace.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            XCTAssertEqual(workspace.editorGroups.editors.count, 2)
            XCTAssertFalse(source.showingDiff)
            XCTAssertTrue(diff.showingDiff)
            XCTAssertEqual(source.right.scroll.contentView.bounds.minY, 500, accuracy: 1)
            XCTAssertEqual(diff.right.scroll.contentView.bounds.minY, 600, accuracy: 1)
            for pane in [source.right, diff.left, diff.right] {
                XCTAssertGreaterThan(pane.bounds.width, 0)
                XCTAssertGreaterThan(pane.scroll.contentView.bounds.height, 0)
                XCTAssertEqual(pane.scroll.scrollerStyle, .overlay)
            }
        }
    }

    func testChangeTreeOpensScopedDiffsAndTabsKeepTheirOwnVersions() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vcode-scope-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src/shared.ts")
        func write(_ version: Int) throws { try "export const version = \(version);\n".write(to: file, atomically: true, encoding: .utf8) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path, "-c", "core.hooksPath=/dev/null"] + args
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try git(["init", "-q", "-b", "main"])
        try git(["config", "user.name", "VCode"]); try git(["config", "user.email", "test@localhost"])
        try git(["config", "commit.gpgsign", "false"])
        try write(1); try git(["add", "."]); try git(["commit", "-qm", "initial"])
        try write(2); try git(["add", "."]); try write(3)
        let controller = WorkspaceController(history: isolatedHistoryStore())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller
        defer { controller.shutdown(); withExtendedLifetime(window) {} }
        let workspace = try XCTUnwrap(controller.view as? WorkspaceView)
        controller.open(root)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in workspace.header.branchButton.title == "main" }, object: nil)], timeout: 10)
        controller.showChanges()
        XCTAssertEqual(workspace.explorer.outline.numberOfRows, 6)
        func choose(_ comparison: GitComparison) {
            workspace.explorer.select("src/shared.ts", comparison: comparison)
            _ = workspace.explorer.outline.sendAction(workspace.explorer.outline.action, to: workspace.explorer.outline.target)
        }
        func expectVersions(_ before: Int, _ after: Int) {
            wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                workspace.editor.left.text.string.contains("version = \(before);") && workspace.editor.right.text.string.contains("version = \(after);")
            }, object: nil)], timeout: 10)
        }
        choose(.staged); expectVersions(1, 2)
        XCTAssertEqual(workspace.editor.activeComparison, .staged)
        choose(.unstaged); expectVersions(2, 3)
        XCTAssertEqual(workspace.editor.activeComparison, .unstaged)
        func buttons(in view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) } }
        let stagedTab = try XCTUnwrap(buttons(in: workspace.editor).first { $0.title == "shared.ts · Staged" })
        stagedTab.performClick(nil)
        expectVersions(1, 2)
        try write(4)
        controller.refresh()
        controller.closeTab()
        expectVersions(2, 4)
        XCTAssertEqual(workspace.editor.activeComparison, .unstaged)
        controller.closeTab()
        XCTAssertFalse(workspace.editor.welcome.isHidden)
        XCTAssertTrue(workspace.editor.left.text.string.isEmpty)
        XCTAssertTrue(workspace.editor.right.text.string.isEmpty)
    }

    func testPickerFiltersAndUsesExplicitWorktreeActionForOccupiedBranch() {
        let root = URL(fileURLWithPath: "/tmp/current", isDirectory: true)
        let other = URL(fileURLWithPath: "/tmp/other", isDirectory: true)
        let picker = GitDestinationPicker(kind: .branches)
        picker.show(GitDestinations(root: root, currentBranch: "main", branches: [GitBranch(name: "main", worktree: root), GitBranch(name: "feature", worktree: other)], worktrees: [GitWorktree(root: root, branch: "main", head: "123", isBare: false, isAvailable: true, note: nil), GitWorktree(root: other, branch: "feature", head: "456", isBare: false, isAvailable: true, note: nil)]))
        XCTAssertEqual(picker.table.numberOfRows, 2)
        XCTAssertEqual(picker.action.title, "Open Worktree")
        var chosen: GitDestination?
        picker.onChoose = { chosen = $0 }
        picker.action.performClick(nil)
        XCTAssertEqual(chosen, .branch("feature"))
        picker.filter.stringValue = "main"
        _ = picker.filter.sendAction(picker.filter.action, to: picker.filter.target)
        XCTAssertEqual(picker.table.numberOfRows, 1)
        XCTAssertFalse(picker.action.isEnabled)
    }
}
