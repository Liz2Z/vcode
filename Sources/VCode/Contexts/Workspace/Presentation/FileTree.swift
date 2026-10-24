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
    private var titleTrailing: NSLayoutConstraint!
    private var badgeTrailing: NSLayoutConstraint!
    private var sectionBadgeTrailing: NSLayoutConstraint!
    var isSection = false {
        didSet {
            guard oldValue != isSection else { return }
            titleTrailing.constant = isSection ? -8 : -7
            badgeTrailing.isActive = !isSection
            sectionBadgeTrailing.isActive = isSection
            badge.alignment = isSection ? .left : .right
            label.setContentHuggingPriority(isSection ? .defaultHigh : .defaultLow, for: .horizontal)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(NSLayoutConstraint.Priority(751), for: .horizontal)
        badge.alignment = .right
        add(label, badge)
        titleTrailing = label.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -7)
        badgeTrailing = badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        sectionBadgeTrailing = badge.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), label.centerYAnchor.constraint(equalTo: centerYAnchor), titleTrailing,
            badgeTrailing, badge.centerYAnchor.constraint(equalTo: centerYAnchor), badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class FileTree: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = FileOutlineView()
    let heading = Theme.label("FILES", size: 10, color: Theme.muted, weight: .semibold)
    let count = Theme.label("", size: 10, color: Theme.muted)
    let emptyLabel = Theme.label("Open a folder to get started", color: Theme.muted)
    let filter = Theme.searchField()
    var onSelect: ((String, GitComparison?) -> Void)?
    var onReveal: ((String) -> Void)?
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
        let menu = NSMenu()
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealFile), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)
        outline.menu = menu
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
        let unchanged = !switching && self.state?.files == state.files && self.state?.changes == state.changes && appliedQuery == filter.stringValue
        self.state = state
        self.changesOnly = changesOnly
        heading.stringValue = changesOnly ? "CHANGES" : "FILES"
        if unchanged { return }
        rebuild(reset: switching)
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
        let allPaths = changesOnly ? state.changes.map(\.path) : state.files
        let paths = query.isEmpty ? allPaths : allPaths.filter { $0.localizedCaseInsensitiveContains(query) }
        index = FileTreeIndex(paths: changesOnly ? [] : paths)
        rebuilding = true
        defer { rebuilding = false }
        nodes = [:]
        sectionIndexes = [:]
        sectionCounts = [:]
        if changesOnly && state.isGit {
            root.children = [GitComparison.staged, .unstaged].map { comparison in
                let selected = state.changes.filter { $0.comparison == comparison && (query.isEmpty || $0.path.localizedCaseInsensitiveContains(query)) }
                sectionIndexes[comparison] = FileTreeIndex(paths: selected.map(\.path))
                sectionCounts[comparison] = selected.count
                let node = FileNode(name: comparison == .staged ? "Staged Changes" : "Unstaged Changes", path: "", directory: true, comparison: comparison, isSection: true)
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
        }
        count.stringValue = "\(paths.count)"
        emptyLabel.stringValue = query.isEmpty ? (changesOnly ? "This folder isn’t a Git repository" : "This folder is empty") : "No matching files"
        emptyLabel.isHidden = !paths.isEmpty || (changesOnly && state.isGit)
    }

    private func children(of parent: FileNode) -> [FileNode] {
        if let children = parent.children { return children }
        let activeIndex = parent.comparison.flatMap { sectionIndexes[$0] } ?? index
        let children = activeIndex.children(in: parent.path).map { entry -> FileNode in
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

    func select(_ path: String, comparison: GitComparison? = nil) {
        let previous = rebuilding
        rebuilding = true
        defer { rebuilding = previous }
        let scope = changesOnly ? (comparison ?? .unstaged) : nil
        var target = scope.flatMap { nodes[key("", comparison: $0)] } ?? root
        if target !== root { outline.expandItem(target) }
        var accumulated = ""
        for component in path.split(separator: "/") {
            accumulated = accumulated.isEmpty ? String(component) : accumulated + "/" + component
            guard let child = children(of: target).first(where: { $0.path == accumulated }) else { return }
            if child.directory { outline.expandItem(child) }
            target = child
        }
        let row = outline.row(forItem: target)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
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
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("file")
        let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? FileCell) ?? FileCell()
        cell.identifier = id
        cell.label.stringValue = node.name
        cell.toolTip = node.path
        let kind = node.change?.kind
        let color = kind == .added || kind == .untracked ? Theme.GitStatus.added : kind == .deleted ? Theme.GitStatus.deleted : Theme.GitStatus.modified
        cell.label.font = .systemFont(ofSize: node.isSection ? 11 : 13, weight: node.isSection ? .semibold : .regular)
        cell.label.textColor = node.isSection ? Theme.muted : Theme.text
        cell.isSection = node.isSection
        cell.badge.stringValue = node.isSection ? "\(sectionCounts[node.comparison ?? .unstaged] ?? 0)" : kind?.rawValue ?? ""
        cell.badge.textColor = node.isSection ? Theme.accent : color
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        if !outline.isHandlingMouse { activateRow() }
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SelectionRowView() }
    @objc private func revealFile() {
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let node = outline.item(atRow: row) as? FileNode, !node.isSection else { return }
        onReveal?(node.path)
    }
}
