import AppKit
import XCTest
@testable import VCode

final class FileTreeTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testPathMenusTargetClickedRowsWithoutChangingSelectionOrExpansion() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let pasteboard = NSPasteboard.withUniqueName()
        tree.pathPasteboard = pasteboard
        defer { pasteboard.releaseGlobally() }
        let path = "src/中文 file.ts"
        var opened: [String] = []
        var revealed: [String] = []
        tree.onSelect = { path, _ in opened.append(path) }
        tree.onReveal = { revealed.append($0) }

        func menu(at row: Int) throws -> NSMenu? {
            let y = row < tree.outline.numberOfRows ? tree.outline.rect(ofRow: row).midY : tree.outline.rect(ofRow: tree.outline.numberOfRows - 1).maxY + 30
            let point = tree.outline.convert(NSPoint(x: 120, y: y), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            return tree.outline.menu(for: event)
        }
        for changesOnly in [false, true] {
            let root = URL(fileURLWithPath: changesOnly ? "/tmp/another worktree 中文" : "/tmp/original project 中文")
            let changes = [GitChange(path: path, kind: .modified, comparison: .staged), GitChange(path: "src/deleted.ts", kind: .deleted, comparison: .unstaged), GitChange(path: "other.ts", kind: .modified, comparison: .unstaged)]
            tree.show(WorkspaceState(root: root, files: [path, "other.ts"], git: GitStatus(root: root, branch: "main", changes: changes, hasHead: true)), changesOnly: changesOnly)
            tree.outline.expandItem(nil, expandChildren: true)
            tree.layoutSubtreeIfNeeded()
            tree.select("other.ts", comparison: changesOnly ? .unstaged : nil)
            let selected = tree.outline.selectedRow
            let targets = changesOnly ? ["src", path, "src/deleted.ts"] : ["src", path]
            for target in targets {
                let row = try XCTUnwrap((0..<tree.outline.numberOfRows).first { (tree.outline.item(atRow: $0) as? FileNode)?.path == target })
                let node = try XCTUnwrap(tree.outline.item(atRow: row) as? FileNode)
                let expanded = tree.outline.isItemExpanded(node)
                let contextMenu = try XCTUnwrap(menu(at: row))
                XCTAssertEqual(contextMenu.items.map(\.title), ["Copy Relative Path", "Copy Absolute Path", "Reveal in Finder"])
                for (index, expected) in [(0, target), (1, root.appendingPathComponent(target).path)] {
                    let item = contextMenu.items[index]
                    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
                    XCTAssertEqual(pasteboard.string(forType: .string), expected)
                }
                let reveal = contextMenu.items[2]
                XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(reveal.action), to: reveal.target, from: reveal))
                XCTAssertEqual(revealed.last, target)
                XCTAssertEqual(tree.outline.selectedRow, selected)
                XCTAssertEqual(tree.outline.isItemExpanded(node), expanded)
                XCTAssertTrue(opened.isEmpty)
                tree.outline.isEnabled = false
                XCTAssertNil(try menu(at: row))
                tree.outline.isEnabled = true
            }
            if changesOnly { XCTAssertNil(try menu(at: 0), "Group headings have no file path") }
            XCTAssertNil(try menu(at: tree.outline.numberOfRows + 2), "Blank space must not reuse the selected file")
        }
    }

    func testDeletedNamesAreStruckOnlyInTheirDeletedComparisonAndResetAfterRefresh() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let root = URL(fileURLWithPath: "/tmp/deleted-name-style")
        let path = "src/a-long-deleted-document-name.md"
        func state(_ kind: GitChangeKind) -> WorkspaceState {
            WorkspaceState(root: root, files: [path], git: GitStatus(root: root, branch: "main", changes: [
                GitChange(path: path, kind: kind, comparison: .staged),
                GitChange(path: path, kind: .untracked, comparison: .unstaged),
                GitChange(path: "src/removed.ts", kind: .deleted, comparison: .unstaged)
            ], hasHead: true))
        }
        for kind in [GitChangeKind.deleted, .modified, .deleted] {
            tree.show(state(kind), changesOnly: true)
            tree.layoutSubtreeIfNeeded()
            for i in 0..<tree.outline.numberOfRows {
                let node = try XCTUnwrap(tree.outline.item(atRow: i) as? FileNode)
                let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: i, makeIfNecessary: true) as? FileCell)
                let deleted = (node.path == path && node.comparison == .staged && kind == .deleted) || node.path == "src/removed.ts"
                let title = cell.label.attributedStringValue
                XCTAssertEqual(title.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, deleted ? 1 : 0)
                XCTAssertEqual(title.string, node.name)
                XCTAssertEqual((title.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineBreakMode, .byTruncatingMiddle)
                if deleted {
                    XCTAssertEqual(cell.badge.stringValue, "D")
                    XCTAssertEqual(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, Theme.muted)
                    cell.setRowHovered(true)
                    XCTAssertFalse(cell.indexButton.isHidden)
                    XCTAssertTrue(cell.indexButton.isEnabled)
                }
            }
            // A staged deletion can coexist with a recreated working file: Files stays unstruck.
            tree.show(state(kind), changesOnly: false)
            tree.outline.expandItem(nil, expandChildren: true)
            for i in 0..<tree.outline.numberOfRows {
                let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: i, makeIfNecessary: true) as? FileCell)
                XCTAssertEqual(cell.label.attributedStringValue.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int, 0)
            }
        }
    }

    func testGroupCountsStayBesideTitlesAndOutsideScrollbarAfterResizeAndCollapse() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let root = URL(fileURLWithPath: "/tmp/group-count-layout")
        let paths = (0..<137).map { "docs/api-\($0).md" }
        let changes = paths.map { GitChange(path: $0, kind: .modified, comparison: .unstaged) }
        tree.show(WorkspaceState(root: root, files: paths, git: GitStatus(root: root, branch: "main", changes: changes, hasHead: true)), changesOnly: true)
        let scroll = try XCTUnwrap(tree.outline.enclosingScrollView)
        XCTAssertEqual(scroll.scrollerStyle, .legacy, "Scrollbar must reserve space rather than cover row contents")
        let section = try XCTUnwrap(tree.outline.item(atRow: 1) as? FileNode)
        for width: CGFloat in [360, 208, 280, 208, 360] {
            window.setContentSize(NSSize(width: width, height: 500))
            for expanded in [true, false, true] {
                if expanded { tree.outline.expandItem(section, expandChildren: true) }
                else { tree.outline.collapseItem(section) }
                tree.layoutSubtreeIfNeeded()
                tree.outline.layoutSubtreeIfNeeded()
                for row in [0, 1] {
                    let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell)
                    cell.layoutSubtreeIfNeeded()
                    XCTAssertTrue(cell.subviews.compactMap { $0 as? NSImageView }.isEmpty)
                    let title = cell.label.alignmentRect(forFrame: cell.label.frame)
                    let badge = cell.badge.alignmentRect(forFrame: cell.badge.frame)
                    XCTAssertEqual(title.minX, 4, accuracy: 0.5, "Hidden folder icon must leave no empty icon slot")
                    XCTAssertEqual(badge.minX - title.maxX, 8, accuracy: 0.5)
                    XCTAssertEqual(cell.badge.alignment, .left)
                    XCTAssertGreaterThanOrEqual(cell.label.frame.width, cell.label.intrinsicContentSize.width - 0.5)
                    XCTAssertGreaterThanOrEqual(cell.badge.frame.width, cell.badge.intrinsicContentSize.width - 0.5)
                    XCTAssertEqual(cell.badge.stringValue, row == 0 ? "0" : "137")
                    let badgeInScroll = cell.badge.convert(cell.badge.bounds, to: scroll)
                    if let scroller = scroll.verticalScroller, !scroller.isHidden {
                        XCTAssertLessThan(scroller.frame.width, NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy), "Reserve a slimmer native track without covering the count")
                        XCTAssertLessThan(badgeInScroll.maxX, scroller.frame.minX)
                    }
                }
            }
        }
    }

    func testReusingSectionCellForFileKeepsIconCollapsedAndTrailingStatus() throws {
        let cell = FileCell()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = cell
        defer { withExtendedLifetime(window) {} }
        cell.label.stringValue = "Unstaged"
        for section in [true, false, true, false] {
            cell.isSection = section
            cell.badge.stringValue = section ? "9" : "M"
            cell.layoutSubtreeIfNeeded()
            XCTAssertTrue(cell.subviews.compactMap { $0 as? NSImageView }.isEmpty)
            let title = cell.label.alignmentRect(forFrame: cell.label.frame)
            let badge = cell.badge.alignmentRect(forFrame: cell.badge.frame)
            if section {
                XCTAssertEqual(title.minX, 4, accuracy: 0.5)
                XCTAssertEqual(badge.minX - title.maxX, 8, accuracy: 0.5)
            } else {
                XCTAssertEqual(title.minX, 4, accuracy: 0.5)
                XCTAssertEqual(badge.maxX, cell.bounds.width - 10, accuracy: 0.5)
                XCTAssertEqual(cell.badge.alignment, .right)
            }
        }
    }

    func testExpandedLongPathsTrackViewportAcrossRepeatedResizes() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let paths = (0..<30).map { "Resources/Brand/Lightsaber/very-long-app-icon-preview-name-\($0).png" }
        let root = URL(fileURLWithPath: "/tmp/sidebar-resize")
        let changes = paths.map { GitChange(path: $0, kind: .modified, comparison: .unstaged) }
        let state = WorkspaceState(root: root, files: paths, git: GitStatus(root: root, branch: "main", changes: changes, hasHead: true))
        tree.show(state, changesOnly: true)
        let scroll = try XCTUnwrap(tree.outline.enclosingScrollView)
        // Include a persistent scroller, so the available width is smaller than the sidebar.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        var measured: [CGFloat: CGFloat] = [:]
        for width: CGFloat in [360, 208, 280, 208, 360] {
            window.setContentSize(NSSize(width: width, height: 500))
            tree.layoutSubtreeIfNeeded()
            tree.outline.layoutSubtreeIfNeeded()
            let column = try XCTUnwrap(tree.outline.outlineTableColumn)
            XCTAssertEqual(column.width, scroll.contentView.bounds.width, accuracy: 1)
            XCTAssertEqual(tree.outline.bounds.width, scroll.contentView.bounds.width, accuracy: 1)
            let row = try XCTUnwrap((0..<tree.outline.numberOfRows).first { (tree.outline.item(atRow: $0) as? FileNode)?.path == paths[0] })
            let cell = try XCTUnwrap(tree.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? FileCell)
            cell.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(cell.label.frame.width, 0)
            let badgeAlignment = cell.badge.alignmentRect(forFrame: cell.badge.frame)
            let labelAlignment = cell.label.alignmentRect(forFrame: cell.label.frame)
            XCTAssertLessThanOrEqual(cell.badge.frame.maxX, cell.bounds.width)
            XCTAssertLessThanOrEqual(badgeAlignment.maxX, cell.bounds.width - 9.5)
            XCTAssertLessThanOrEqual(labelAlignment.maxX, badgeAlignment.minX - 6.5)
            XCTAssertTrue(cell.subviews.compactMap { $0 as? NSImageView }.isEmpty)
            if let previous = measured[width] { XCTAssertEqual(cell.label.frame.width, previous, accuracy: 1, "Returning to a width must restore the same text area") }
            measured[width] = cell.label.frame.width
            tree.outline.collapseItem(tree.outline.item(atRow: 1))
            tree.outline.expandItem(nil, expandChildren: true)
        }
        XCTAssertGreaterThan(try XCTUnwrap(measured[360]), try XCTUnwrap(measured[208]) + 140)
    }

    func testIndexOnlyReturnsImmediateChildrenWithNaturalDirectoryOrder() {
        let index = FileTreeIndex(paths: ["src/module10/main.ts", "src/module2/你好.ts", "src/a.ts", "src-old/file.ts", "README.md"])
        XCTAssertEqual(index.children(in: "").map(\.path), ["src", "src-old", "README.md"])
        XCTAssertEqual(index.children(in: "src").map(\.path), ["src/module2", "src/module10", "src/a.ts"])
        XCTAssertEqual(index.children(in: "src/module2").map(\.name), ["你好.ts"])
        XCTAssertTrue(index.children(in: "missing").isEmpty)
    }

    func testFiftyThousandFilesStayCollapsedAndOnlyExpandedNodesMaterialize() throws {
        let tree = FileTree()
        let paths = (0..<100).flatMap { directory in (0..<500).map { "src/module\(directory)/file\($0).ts" } }
        let state = WorkspaceState(root: URL(fileURLWithPath: "/tmp/lazy-tree"), files: paths, git: GitStatus(root: URL(fileURLWithPath: "/tmp/lazy-tree"), branch: "main", changes: [], hasHead: true))
        tree.show(state, changesOnly: false)
        XCTAssertEqual(tree.outline.numberOfRows, 1)
        XCTAssertEqual(tree.loadedNodeCount, 1)
        let src = try XCTUnwrap(tree.outline.item(atRow: 0) as? FileNode)
        XCTAssertFalse(tree.outline.isItemExpanded(src))
        tree.outline.expandItem(src)
        XCTAssertEqual(tree.outline.numberOfRows, 101)
        XCTAssertEqual(tree.loadedNodeCount, 101)
        let module = try XCTUnwrap(tree.outline.item(atRow: 1) as? FileNode)
        XCTAssertFalse(tree.outline.isItemExpanded(module))
        tree.outline.expandItem(module)
        XCTAssertEqual(tree.outline.numberOfRows, 601)
        XCTAssertEqual(tree.loadedNodeCount, 601)
        tree.show(state, changesOnly: false)
        XCTAssertTrue(tree.outline.item(atRow: 0) as? FileNode === src, "An unchanged refresh must keep the existing tree")
        tree.outline.collapseItem(src)
        let refreshed = WorkspaceState(root: state.root, files: paths + ["src/new/added.ts"], git: GitStatus(root: state.root, branch: state.branch, changes: [], hasHead: true))
        tree.show(refreshed, changesOnly: false)
        XCTAssertEqual(tree.outline.numberOfRows, 1)
        XCTAssertEqual(tree.loadedNodeCount, 1, "A refresh must not materialize descendants of a collapsed parent")
        tree.select("src/module99/file499.ts")
        XCTAssertEqual((tree.outline.item(atRow: tree.outline.selectedRow) as? FileNode)?.path, "src/module99/file499.ts")
        XCTAssertLessThan(tree.loadedNodeCount, 1200)
    }

    func testChangesStartExpandedAndSearchOnlyMaterializesMatchingPaths() throws {
        let tree = FileTree()
        let state = WorkspaceState(root: URL(fileURLWithPath: "/tmp/changes-tree"), files: ["src/lib/target.ts", "src/other/ignored.ts"], git: GitStatus(root: URL(fileURLWithPath: "/tmp/changes-tree"), branch: "main", changes: [GitChange(path: "src/lib/target.ts", kind: .modified), GitChange(path: "src/other/ignored.ts", kind: .added)], hasHead: true))
        tree.show(state, changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 7)
        XCTAssertEqual(tree.loadedNodeCount, 7)
        tree.filter.stringValue = "target"
        tree.show(state, changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 5)
        XCTAssertEqual(tree.loadedNodeCount, 5)
        tree.filter.stringValue = ""
        tree.show(state, changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 7)
    }
    func testBothChangeSectionsShowSamePathAndPreserveExplicitCollapses() throws {
        let tree = FileTree()
        let root = URL(fileURLWithPath: "/tmp/scoped-changes")
        let path = "src/lib/shared.ts"
        let changes = [GitChange(path: path, kind: .modified, comparison: .staged), GitChange(path: path, kind: .modified, comparison: .unstaged)]
        let status = GitStatus(root: root, branch: "main", changes: changes, hasHead: true)
        tree.show(WorkspaceState(root: root, files: [path], git: status), changesOnly: true)
        XCTAssertEqual(tree.outline.numberOfRows, 8)
        let nodes = (0..<8).compactMap { tree.outline.item(atRow: $0) as? FileNode }
        XCTAssertEqual(nodes.filter { $0.path == path }.count, 2)
        XCTAssertTrue(nodes.filter(\.directory).allSatisfy { tree.outline.isItemExpanded($0) })
        var selected: GitComparison?
        tree.onSelect = { _, scope in selected = scope }
        tree.select(path, comparison: .staged)
        _ = tree.outline.sendAction(tree.outline.action, to: tree.outline.target)
        XCTAssertEqual(selected, .staged)
        tree.select(path, comparison: .unstaged)
        _ = tree.outline.sendAction(tree.outline.action, to: tree.outline.target)
        XCTAssertEqual(selected, .unstaged)
        let staged = try XCTUnwrap(nodes.first { $0.isSection && $0.comparison == .staged })
        tree.outline.collapseItem(staged)
        let extra = GitChange(path: "other/file.ts", kind: .untracked, comparison: .unstaged)
        let next = GitStatus(root: root, branch: "main", changes: changes + [extra], hasHead: true)
        tree.show(WorkspaceState(root: root, files: [path, extra.path], git: next), changesOnly: true)
        let refreshedStaged = try XCTUnwrap(tree.outline.item(atRow: 0) as? FileNode)
        XCTAssertFalse(tree.outline.isItemExpanded(refreshedStaged))
        XCTAssertTrue((0..<tree.outline.numberOfRows).compactMap { tree.outline.item(atRow: $0) as? FileNode }.contains { $0.path == extra.path })
    }

    func testFilteredFilesActivateOnceAfterChangesRoundTripAndRefreshWithoutResizing() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let paths = ["src/auth/request.ts", "src/account/uic-request.ts", "src/xiaolv/request.ts"]
        let changes = (paths + ["src/other/ignored.ts"]).flatMap { path in [GitChange(path: path, kind: .modified, comparison: .staged), GitChange(path: path, kind: .modified, comparison: .unstaged)] }
        let root = URL(fileURLWithPath: "/tmp/filtered-clicks")
        let state = WorkspaceState(root: root, files: paths + ["src/other/ignored.ts"], git: GitStatus(root: root, branch: "main", changes: changes, hasHead: true))
        tree.show(state, changesOnly: true)
        tree.filter.stringValue = "request.ts"
        _ = tree.filter.sendAction(tree.filter.action, to: tree.filter.target)
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tree.count.stringValue == "6" }, object: nil)], timeout: 2)
        var activated: [(String, GitComparison?)] = []
        tree.onSelect = { activated.append(($0, $1)) }
        for changesOnly in [false, true, false] {
            tree.show(state, changesOnly: changesOnly)
            tree.layoutSubtreeIfNeeded()
            for path in paths + [paths[0], paths[0]] {
                let scope: GitComparison? = changesOnly ? .unstaged : nil
                let row = try XCTUnwrap((0..<tree.outline.numberOfRows).first { row in
                    guard let node = tree.outline.item(atRow: row) as? FileNode else { return false }
                    return node.path == path && node.comparison == scope
                })
                let point = tree.outline.convert(NSPoint(x: 130, y: tree.outline.rect(ofRow: row).midY), to: nil)
                let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
                let previous = activated.count
                // Also bounds the old native tracking loop if this behavior regresses.
                NSApp.postEvent(up, atStart: true)
                tree.outline.mouseDown(with: down)
                _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
                tree.outline.mouseUp(with: up)
                XCTAssertEqual(tree.outline.selectedRow, row)
                XCTAssertEqual(activated.count, previous + 1)
                XCTAssertEqual(activated.last?.0, path)
                XCTAssertEqual(activated.last?.1, scope)
            }
            tree.show(state, changesOnly: changesOnly)
        }
    }

    func testFilePressCancelsWhenDraggedOutOrReloadedBeforeRelease() throws {
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let state = WorkspaceState(root: URL(fileURLWithPath: "/tmp/cancel-file-click"), files: ["first.ts", "second.ts"], git: nil)
        tree.show(state, changesOnly: false)
        tree.layoutSubtreeIfNeeded()
        var opened = 0
        tree.onSelect = { _, _ in opened += 1 }
        func event(_ type: NSEvent.EventType, row: Int) throws -> NSEvent {
            let point = tree.outline.convert(NSPoint(x: 120, y: tree.outline.rect(ofRow: row).midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        tree.outline.mouseDown(with: try event(.leftMouseDown, row: 0))
        tree.outline.mouseDragged(with: try event(.leftMouseDragged, row: 1))
        tree.outline.mouseUp(with: try event(.leftMouseUp, row: 1))
        XCTAssertEqual(opened, 0)
        tree.outline.mouseDown(with: try event(.leftMouseDown, row: 0))
        tree.filter.stringValue = "second"
        tree.show(state, changesOnly: false)
        tree.outline.mouseUp(with: try event(.leftMouseUp, row: 0))
        XCTAssertEqual(opened, 0, "Reload must cancel a press rather than activate the replacement row")
    }

    func testFolderNameAndBlankSpaceToggleOnceAndExposePressedFeedback() throws {
        _ = NSApplication.shared
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        let root = URL(fileURLWithPath: "/tmp/row-click")
        tree.show(WorkspaceState(root: root, files: ["src/lib/file.ts"], git: nil), changesOnly: false)
        tree.layoutSubtreeIfNeeded()
        let folder = try XCTUnwrap(tree.outline.item(atRow: 0) as? FileNode)
        func click(x: CGFloat, expectedExpanded: Bool) throws {
            let point = tree.outline.convert(NSPoint(x: x, y: tree.outline.rect(ofRow: 0).midY), to: nil)
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0.1, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            tree.outline.mouseDown(with: down)
            let row = try XCTUnwrap(tree.outline.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
            XCTAssertTrue(row.isPressed)
            tree.outline.mouseUp(with: up)
            XCTAssertFalse(row.isPressed)
            XCTAssertEqual(tree.outline.isItemExpanded(folder), expectedExpanded)
            row.mouseEntered(with: down)
            XCTAssertTrue(row.isHovered)
            row.mouseExited(with: down)
            XCTAssertFalse(row.isHovered)
        }
        try click(x: 75, expectedExpanded: true)
        try click(x: tree.outline.bounds.width - 8, expectedExpanded: false)
        try click(x: 8, expectedExpanded: true)
        XCTAssertEqual(tree.loadedNodeCount, 2, "Only one directory level should load")
    }

    func testDraggingOutCancelsFolderToggleAndMovesHoverToAnotherRow() throws {
        _ = NSApplication.shared
        let tree = FileTree()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = tree
        defer { withExtendedLifetime(window) {} }
        tree.show(WorkspaceState(root: URL(fileURLWithPath: "/tmp/pointer-tracking"), files: ["docs/note.md", "src/code.ts"], git: nil), changesOnly: false)
        tree.layoutSubtreeIfNeeded()
        func event(_ type: NSEvent.EventType, row: Int) throws -> NSEvent {
            let point = tree.outline.convert(NSPoint(x: 120, y: tree.outline.rect(ofRow: row).midY), to: nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        let src = try XCTUnwrap(tree.outline.item(atRow: 1) as? FileNode)
        tree.outline.mouseDown(with: try event(.leftMouseDown, row: 1))
        let selected = try XCTUnwrap(tree.outline.rowView(atRow: 1, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertTrue(selected.isPressed)
        tree.outline.mouseDragged(with: try event(.leftMouseDragged, row: 0))
        let hovered = try XCTUnwrap(tree.outline.rowView(atRow: 0, makeIfNecessary: true) as? SelectionRowView)
        XCTAssertFalse(selected.isPressed)
        XCTAssertTrue(hovered.isHovered)
        tree.outline.mouseUp(with: try event(.leftMouseUp, row: 0))
        XCTAssertFalse(tree.outline.isItemExpanded(src), "Releasing outside the original row cancels the folder action")
        tree.outline.mouseExited(with: try event(.mouseMoved, row: 0))
        XCTAssertFalse(hovered.isHovered)
    }

}
