import AppKit

final class FileNode: NSObject {
    let name: String
    let path: String
    let directory: Bool
    var children: [FileNode]?
    var change: GitChange?
    let comparison: GitComparison?
    let isSection: Bool
    var identity: String { (comparison?.rawValue ?? "files") + "\0" + path }

    init(name: String, path: String, directory: Bool, comparison: GitComparison? = nil, isSection: Bool = false) {
        self.name = name
        self.path = path
        self.directory = directory
        self.comparison = comparison
        self.isSection = isSection
    }
}

final class FileCell: NSTableCellView {
    let label = Theme.label("", size: 13)
    let badge = Theme.label("", size: 10, weight: .semibold)
    let indexButton = Theme.button("plus", tooltip: "Stage Changes", target: nil, action: nil)
    var onIndexAction: (() -> Void)?
    var isIndexBusy = false
    private(set) var indexActionAvailable = true
    private var hasIndexAction = false
    private var rowHovered = false
    private var titleTrailing: NSLayoutConstraint!
    private var actionTitleTrailing: NSLayoutConstraint!
    private var badgeTrailing: NSLayoutConstraint!
    private var sectionBadgeTrailing: NSLayoutConstraint!
    private var sectionBadgeBeforeAction: NSLayoutConstraint!
    private var fileActionTrailing: NSLayoutConstraint!
    private var sectionActionTrailing: NSLayoutConstraint!
    private var directoryActionTrailing: NSLayoutConstraint!
    private var directoryTitleTrailing: NSLayoutConstraint!
    var isSection = false { didSet { updateLayout() } }
    var isDirectory = false { didSet { updateLayout() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        badge.alignment = .right
        indexButton.feedbackRadius = 4
        indexButton.horizontalPadding = 0
        indexButton.isHidden = true
        indexButton.target = self
        indexButton.action = #selector(changeIndex)
        add(label, indexButton, badge)
        titleTrailing = label.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -7)
        actionTitleTrailing = label.trailingAnchor.constraint(equalTo: indexButton.leadingAnchor, constant: -4)
        badgeTrailing = badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        sectionBadgeTrailing = badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        sectionBadgeBeforeAction = badge.trailingAnchor.constraint(lessThanOrEqualTo: indexButton.leadingAnchor, constant: -4)
        fileActionTrailing = indexButton.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4)
        sectionActionTrailing = indexButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        directoryActionTrailing = indexButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        directoryTitleTrailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor), badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            indexButton.centerYAnchor.constraint(equalTo: centerYAnchor), indexButton.widthAnchor.constraint(equalToConstant: 22), indexButton.heightAnchor.constraint(equalToConstant: 22)
        ])
        updateLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateLayout() {
        guard titleTrailing != nil else { return }
        NSLayoutConstraint.deactivate([titleTrailing, actionTitleTrailing, badgeTrailing, sectionBadgeTrailing,
                                        sectionBadgeBeforeAction, fileActionTrailing, sectionActionTrailing,
                                        directoryActionTrailing, directoryTitleTrailing])
        titleTrailing.constant = isSection ? -8 : -7
        if isSection {
            NSLayoutConstraint.activate([titleTrailing, sectionActionTrailing,
                hasIndexAction ? sectionBadgeBeforeAction : sectionBadgeTrailing])
        } else if isDirectory {
            NSLayoutConstraint.activate([hasIndexAction ? actionTitleTrailing : directoryTitleTrailing, directoryActionTrailing, badgeTrailing])
        } else {
            NSLayoutConstraint.activate([hasIndexAction ? actionTitleTrailing : titleTrailing, badgeTrailing, fileActionTrailing])
        }
        badge.alignment = isSection ? .left : .right
        badge.isHidden = isDirectory && !isSection
        label.setContentHuggingPriority(isSection ? .defaultHigh : .defaultLow, for: .horizontal)
    }

    func configureIndexAction(_ action: GitIndexAction?, path: String, enabled: Bool, available: Bool = true) {
        hasIndexAction = action != nil
        indexActionAvailable = available
        updateLayout()
        updateIndexAvailability(outlineEnabled: enabled)
        indexButton.image = action.flatMap { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) }
        let description = action.map { isSection ? $0.allTitle : $0.title + " · " + path }
        indexButton.toolTip = description
        indexButton.setAccessibilityLabel(description)
        if action == nil { onIndexAction = nil }
        setRowHovered(rowHovered)
    }

    func updateIndexAvailability(outlineEnabled: Bool) {
        indexButton.isEnabled = outlineEnabled && !isIndexBusy && indexActionAvailable
    }

    func setRowHovered(_ hovered: Bool) {
        rowHovered = hovered
        // Keep the space reserved even while hidden, so names and counts never jump.
        indexButton.isHidden = !hasIndexAction || !hovered
        indexButton.refreshHover()
    }

    @objc private func changeIndex() {
        guard indexButton.isEnabled, !indexButton.isHidden else { return }
        onIndexAction?()
    }
}

final class FileTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = FileOutlineView()
    let heading = Theme.label("FILES", size: 10, color: Theme.muted, weight: .semibold)
    let count = Theme.label("", size: 10, color: Theme.muted)
    let emptyLabel = Theme.label("Open a folder to get started", color: Theme.muted)
    let filter = Theme.searchField()
    var onIndexAction: ((GitIndexAction, GitChangeTarget) -> Void)?
    private(set) var isIndexBusy = false
    var onSelect: ((String, GitComparison?) -> Void)?
    var onReveal: ((String) -> Void)?
    var onRevealInFiles: ((String) -> Void)?
    var canRevealInFiles: ((String) -> Bool)?
    var pathPasteboard: NSPasteboard = .general
    var loadDirectory: ((String) throws -> [FileTreeEntry])?
    var onLoadError: ((Error) -> Void)?
    var onExpandedDirectoriesChange: ((Set<String>) -> Void)?
    private let root = FileNode(name: "", path: "", directory: true)
    private var rebuilding = false
    private var state: WorkspaceState?
    private var changesOnly = false
    private var nodes: [String: FileNode] = [:]
    private var index = FileTreeIndex(paths: [])
    private var changes: [String: GitChange] = [:]
    private var sectionIndexes: [GitComparison: FileTreeIndex] = [:]
    private var sectionCounts: [GitComparison: Int] = [:]
    private var appliedQuery = ""
    private var expandedBeforeSearch: Set<String> = []
    private var collapsedBeforeSearch: Set<String> = []
    private var filterWork: DispatchWorkItem?
    var loadedNodeCount: Int { nodes.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 30
        outline.indentationPerLevel = 13
        outline.style = .plain
        outline.selectionHighlightStyle = .regular
        outline.floatsGroupRows = false
        outline.allowsEmptySelection = true
        // Expansion must not grow the document beyond the visible sidebar.
        outline.autoresizesOutlineColumn = false
        outline.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("files"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(activateRow)
        outline.intercellSpacing = NSSize(width: 0, height: 0)
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.onContextMenu = { [weak self] node in self?.contextMenu(for: node) }
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        Theme.compactScrollers(scroll)
        scroll.hasHorizontalScroller = false
        // Keep the scrollbar in its own gutter instead of covering row content.
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        filter.placeholderString = "Filter files"
        filter.font = .systemFont(ofSize: 12)
        filter.focusRingType = .none
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.sendsSearchStringImmediately = true
        filter.sendsWholeSearchString = false
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 2
        add(heading, count, filter, scroll, emptyLabel)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), heading.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Layout.moduleGap),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), count.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            filter.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: Theme.Layout.controlGap), filter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), filter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), filter.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: Theme.Layout.controlGap), scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.controlGap), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.controlGap), scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Layout.controlGap),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor), emptyLabel.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 50), emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12), emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: WorkspaceState, changesOnly: Bool) {
        let switching = self.changesOnly != changesOnly || self.state?.root != state.root
        let readingDeferredFolder = !changesOnly && nodes.values.contains {
            $0.directory && state.isDeferredDirectory($0.path) && outline.isItemExpanded($0)
        }
        let unchanged = !switching && !readingDeferredFolder && self.state?.files == state.files
            && self.state?.directories == state.directories && self.state?.deferredDirectories == state.deferredDirectories
            && self.state?.searchableFiles == state.searchableFiles && self.state?.ignoredPaths == state.ignoredPaths
            && self.state?.changes == state.changes && appliedQuery == filter.stringValue
        self.state = state
        self.changesOnly = changesOnly
        heading.stringValue = changesOnly ? "CHANGES" : "FILES"
        if unchanged { return }
        rebuild(reset: switching)
    }

    func setIndexBusy(_ busy: Bool) {
        isIndexBusy = busy
        outline.enumerateAvailableRowViews { rowView, row in
            guard let cell = self.outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell else { return }
            cell.isIndexBusy = busy
            cell.updateIndexAvailability(outlineEnabled: self.outline.isEnabled)
            rowView.needsDisplay = true
        }
        outline.window?.invalidateCursorRects(for: outline)
    }

    func captureSession() -> FileTreeReadingState {
        let folders = nodes.values.filter { $0.directory }
        return FileTreeReadingState(
            expanded: (appliedQuery.isEmpty ? folders.filter { outline.isItemExpanded($0) }.map(\.identity) : Array(expandedBeforeSearch)).sorted(),
            collapsed: (appliedQuery.isEmpty ? folders.filter { !outline.isItemExpanded($0) }.map(\.identity) : Array(collapsedBeforeSearch)).sorted(),
            selection: (outline.item(atRow: outline.selectedRow) as? FileNode)?.identity,
            query: filter.stringValue, scrollOffset: Double(outline.enclosingScrollView?.contentView.bounds.minY ?? 0))
    }

    func restoreSession(_ saved: FileTreeReadingState) {
        filterWork?.cancel()
        filter.stringValue = saved.query
        rebuild(reset: true, restoring: saved)
        if let scroll = outline.enclosingScrollView, saved.scrollOffset.isFinite {
            outline.layoutSubtreeIfNeeded()
            let y = min(max(0, saved.scrollOffset), max(0, outline.bounds.height - scroll.contentView.bounds.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @objc private func filterChanged() {
        filterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild(reset: false) }
        filterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
    deinit { filterWork?.cancel() }

    private func key(_ path: String, comparison: GitComparison?) -> String {
        (comparison?.rawValue ?? "files") + "\0" + path
    }

    private func rebuild(reset: Bool, restoring saved: FileTreeReadingState? = nil) {
        guard let state else { return }
        let visibleFolders = nodes.values.filter { $0.directory && outline.row(forItem: $0) >= 0 }
        var expanded = reset ? Set<String>() : Set(visibleFolders.filter { outline.isItemExpanded($0) }.map(\.identity))
        var collapsed = reset ? Set<String>() : Set(visibleFolders.filter { !outline.isItemExpanded($0) }.map(\.identity))
        let selection = saved?.selection ?? (reset ? nil : (outline.item(atRow: outline.selectedRow) as? FileNode)?.identity)
        let query = filter.stringValue
        if let saved {
            expanded = Set(saved.expanded); collapsed = Set(saved.collapsed)
            expandedBeforeSearch = expanded; collapsedBeforeSearch = collapsed
        } else if reset { expandedBeforeSearch = []; collapsedBeforeSearch = [] }
        else if appliedQuery.isEmpty && !query.isEmpty { expandedBeforeSearch = expanded; collapsedBeforeSearch = collapsed }
        else if !appliedQuery.isEmpty && query.isEmpty { expanded = expandedBeforeSearch; collapsed = collapsedBeforeSearch }
        appliedQuery = query
        changes = [:]
        for change in state.changes {
            changes[key(change.path, comparison: change.comparison)] = change
            let sourceKey = key(change.path, comparison: nil)
            if changes[sourceKey] == nil || change.comparison == .unstaged { changes[sourceKey] = change }
        }
        let allPaths = changesOnly ? state.changes.map(\.path) : (query.isEmpty ? state.files + state.directories.map { $0 + "/" } : state.searchableFiles)
        let paths = query.isEmpty ? allPaths : allPaths.filter { $0.localizedCaseInsensitiveContains(query) }
        index = FileTreeIndex(paths: changesOnly ? [] : paths)
        rebuilding = true
        defer { rebuilding = false; notifyExpandedDirectories() }
        nodes = [:]
        sectionIndexes = [:]
        sectionCounts = [:]
        if changesOnly && state.isGit {
            root.children = [GitComparison.staged, .unstaged].map { comparison in
                let selected = state.changes.filter { $0.comparison == comparison && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) }
                sectionIndexes[comparison] = FileTreeIndex(paths: selected.map(\.path))
                sectionCounts[comparison] = selected.count
                let node = FileNode(name: comparison == .staged ? "Staged" : "Unstaged", path: "", directory: true, comparison: comparison, isSection: true)
                nodes[node.identity] = node
                return node
            }
        } else { root.children = nil }
        outline.reloadData()
        if changesOnly || !query.isEmpty {
            outline.expandItem(nil, expandChildren: true)
            // New diff directories open by default; explicit user collapses survive refreshes.
            if query.isEmpty {
                for identity in collapsed.sorted(by: { $0.count < $1.count }) {
                    if let node = nodes[identity] { outline.collapseItem(node) }
                }
            }
        } else {
            for identity in expanded.sorted(by: { $0.count < $1.count }) {
                let path = String(identity.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).last ?? "")
                if let node = node(at: path, comparison: nil) { outline.expandItem(node) }
            }
        }
        if let selection, let node = nodes[selection], outline.row(forItem: node) >= 0 {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: node)), byExtendingSelection: false)
        } else {
            // Staging can remove the selected item from this category. Do not
            // leave its former row index selected on an unrelated file.
            outline.deselectAll(nil)
        }
        count.stringValue = changesOnly || !query.isEmpty ? "\(paths.count)" : "\(state.files.count)" + (state.deferredDirectories.isEmpty ? "" : "+")
        count.toolTip = !changesOnly && query.isEmpty && !state.deferredDirectories.isEmpty ? "More files are available in collapsed folders." : nil
        emptyLabel.stringValue = query.isEmpty ? (changesOnly ? "This folder isn’t a Git repository" : "This folder is empty") : "No matching files"
        emptyLabel.isHidden = !paths.isEmpty || (changesOnly && state.isGit)
    }

    private func children(of parent: FileNode) -> [FileNode] {
        if let children = parent.children { return children }
        let activeIndex = parent.comparison.flatMap { sectionIndexes[$0] } ?? index
        let entries: [FileTreeEntry]
        if !changesOnly, appliedQuery.isEmpty, state?.isDeferredDirectory(parent.path) == true, let loadDirectory {
            do { entries = try loadDirectory(parent.path) }
            catch { onLoadError?(error); entries = [] }
        } else { entries = activeIndex.children(in: parent.path) }
        let children = entries.map { entry -> FileNode in
            let node = FileNode(name: entry.name, path: entry.path, directory: entry.directory, comparison: parent.comparison)
            node.change = changes[node.identity]
            nodes[node.identity] = node
            return node
        }
        parent.children = children
        return children
    }

    private func node(at path: String, comparison: GitComparison?) -> FileNode? {
        var parent = comparison.flatMap { nodes[key("", comparison: $0)] } ?? root
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(component) : accumulated + "/" + component
            guard let child = children(of: parent).first(where: { $0.path == accumulated }) else { return nil }
            parent = child
        }
        return parent
    }

    @discardableResult
    func select(_ path: String, comparison: GitComparison? = nil) -> Bool {
        let previous = rebuilding
        rebuilding = true
        defer { rebuilding = previous; if !previous { notifyExpandedDirectories() } }
        let scope = changesOnly ? (comparison ?? .unstaged) : nil
        var target = scope.flatMap { nodes[key("", comparison: $0)] } ?? root
        if target !== root { outline.expandItem(target) }
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(component) : accumulated + "/" + component
            guard let child = children(of: target).first(where: { $0.path == accumulated }) else { return false }
            if child.directory { outline.expandItem(child) }
            target = child
        }
        let row = outline.row(forItem: target)
        guard row >= 0 else { return false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        return true
    }

    @discardableResult
    func revealInFiles(_ path: String) -> Bool {
        guard !changesOnly, outline.isEnabled else { return false }
        filterWork?.cancel(); filterWork = nil
        if !filter.stringValue.isEmpty {
            filter.stringValue = ""
            rebuild(reset: false)
        }
        return select(path)
    }

    private var selectedFile: FileNode? {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.directory else { return nil }
        return node
    }

    @objc private func activateRow() {
        guard !rebuilding, let node = selectedFile else { return }
        onSelect?(node.path, node.comparison)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: (item as? FileNode) ?? root).count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: (item as? FileNode) ?? root)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? FileNode)?.directory == true }
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        if !rebuilding, !changesOnly, appliedQuery.isEmpty, let node = item as? FileNode, state?.isDeferredDirectory(node.path) == true {
            // Reopening an ignored folder must see its current disk contents.
            for identity in nodes.keys.filter({ $0.hasPrefix(node.identity + "/") }) { nodes.removeValue(forKey: identity) }
            node.children = nil
        }
        return true
    }
    func outlineViewItemDidExpand(_ notification: Notification) { if !rebuilding { notifyExpandedDirectories() } }
    func outlineViewItemDidCollapse(_ notification: Notification) { if !rebuilding { notifyExpandedDirectories() } }
    private func notifyExpandedDirectories() {
        let paths = changesOnly || !appliedQuery.isEmpty ? [] : nodes.values.filter {
            $0.directory && state?.isDeferredDirectory($0.path) == true && outline.row(forItem: $0) >= 0 && outline.isItemExpanded($0)
        }.map(\.path)
        onExpandedDirectoriesChange?(Set(paths))
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell()
        cell.identifier = id
        cell.toolTip = node.path
        let kind = node.change?.kind
        let color = kind == .added || kind == .untracked ? Theme.GitStatus.added : kind == .deleted ? Theme.GitStatus.deleted : Theme.GitStatus.modified
        let deleted = changesOnly && !node.directory && kind == .deleted
        let ignored = !changesOnly && state?.isGitIgnored(node.path) == true
        cell.label.font = .systemFont(ofSize: node.isSection ? 11 : 13, weight: node.isSection ? .semibold : .regular)
        cell.label.textColor = ignored ? Theme.GitStatus.ignored : node.isSection || deleted ? Theme.muted : Theme.text
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        cell.label.attributedStringValue = NSAttributedString(string: node.name, attributes: [
            .font: cell.label.font!, .foregroundColor: cell.label.textColor!, .paragraphStyle: paragraph,
            .strikethroughStyle: deleted ? NSUnderlineStyle.single.rawValue : 0
        ])
        cell.isSection = node.isSection
        cell.isDirectory = node.directory
        cell.badge.stringValue = node.isSection ? "\(sectionCounts[node.comparison ?? .unstaged] ?? 0)" : kind?.rawValue ?? ""
        cell.badge.textColor = node.isSection ? Theme.accent : color
        let action: GitIndexAction? = changesOnly && state?.isGit == true
            ? node.comparison == .staged ? .unstage : .stage : nil
        cell.isIndexBusy = isIndexBusy
        let available = !node.isSection || state?.changes.contains { $0.comparison == node.comparison } == true
        cell.configureIndexAction(action, path: node.path, enabled: outline.isEnabled, available: available)
        let row = outline.row(forItem: node)
        cell.setRowHovered(row >= 0 && (outline.rowView(atRow: row, makeIfNecessary: false) as? SelectionRowView)?.isHovered == true)
        cell.onIndexAction = action.map { action in { [weak self, weak node] in
            guard let self, let node, self.nodes[node.identity] === node,
                  self.outline.isEnabled, !self.isIndexBusy else { return }
            self.onIndexAction?(action, node.isSection ? .all : node.directory ? .directory(node.path) : .file(node.path))
        } }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !outline.isHandlingMouse { activateRow() }
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SelectionRowView() }
    private func contextMenu(for node: FileNode) -> NSMenu? {
        guard let state, !node.isSection, !node.path.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, path, action) in [
            ("Copy Relative Path", node.path, #selector(copyPath(_:))),
            ("Copy Absolute Path", state.root.appendingPathComponent(node.path).path, #selector(copyPath(_:))),
            ("Reveal in Finder", node.path, #selector(revealFile(_:)))
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = path
            menu.addItem(item)
        }
        if changesOnly {
            let reveal = NSMenuItem(title: "Reveal in Files", action: #selector(viewInFiles(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = FilesRevealTarget(root: state.root, path: node.path)
            reveal.isEnabled = onRevealInFiles != nil && isAvailableInFiles(node.path)
            menu.insertItem(reveal, at: 2)
        }
        return menu
    }

    private struct FilesRevealTarget {
        let root: URL
        let path: String
    }

    private func isAvailableInFiles(_ path: String) -> Bool {
        if let canRevealInFiles { return canRevealInFiles(path) }
        guard let state else { return false }
        return state.files.contains(path) || state.directories.contains(path)
            || state.files.contains { $0.hasPrefix(path + "/") }
    }

    @objc private func viewInFiles(_ item: NSMenuItem) {
        guard outline.isEnabled, changesOnly, let target = item.representedObject as? FilesRevealTarget,
              state?.root == target.root, isAvailableInFiles(target.path) else { return }
        onRevealInFiles?(target.path)
    }

    @objc private func copyPath(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        pathPasteboard.clearContents()
        pathPasteboard.setString(path, forType: .string)
    }

    @objc private func revealFile(_ item: NSMenuItem) {
        guard let path = item.representedObject as? String else { return }
        onReveal?(path)
    }
}
