import AppKit

final class WorkspaceHistoryPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case project(RecentProject), workspace(RecentWorkspace) }
    var onChoose: ((URL) -> Void)?
    let filter = NSSearchField()
    let table = HistoryTableView()
    private let scroll = NSScrollView()
    private let empty = Theme.label("No recent projects yet", size: 12, color: Theme.muted)
    private let entries: [RecentWorkspace]
    private let current: URL?
    private let available: (URL) -> Bool
    private(set) var rows: [Row] = []
    var preferredHeight: CGFloat {
        min(440, max(180, 110 + CGFloat(RecentProject.group(entries).count * 36 + entries.count * 56)))
    }

    init(entries: [RecentWorkspace], current: URL?, available: @escaping (URL) -> Bool) {
        self.entries = entries; self.current = current; self.available = available
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = FloatingSurface(frame: NSRect(x: 0, y: 0, width: 560, height: preferredHeight))
        let title = Theme.label("Recent projects & worktrees", size: 15, weight: .semibold)
        filter.placeholderString = "Filter projects, worktrees or paths"
        filter.font = .systemFont(ofSize: 12)
        filter.focusRingType = .none
        filter.sendsSearchStringImmediately = true
        filter.sendsWholeSearchString = false
        filter.target = self; filter.action = #selector(filterChanged)
        filter.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("history"))
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = Theme.floating
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(choose)
        table.focusRingType = .none
        table.onEscape = { [weak self] in self?.onDismiss?() }
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        Theme.compactScrollers(scroll)
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view.add(title, filter, scroll, empty)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            filter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12), filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), filter.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor)
        ])
        applyFilter()
    }
    var onDismiss: (() -> Void)?

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(filter)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let column = table.tableColumns.first, table.bounds.width > 0, abs(column.width - table.bounds.width) > 1 { column.width = table.bounds.width }
        let height = rows.isEmpty ? 0 : table.rect(ofRow: rows.count - 1).maxY
        let overflowing = height > scroll.contentSize.height + 0.5
        if scroll.hasVerticalScroller != overflowing { scroll.hasVerticalScroller = overflowing }
        Theme.compactScrollers(scroll)
    }

    private func applyFilter() {
        rows = RecentProject.group(entries, matching: filter.stringValue).flatMap { [.project($0)] + $0.workspaces.map { .workspace($0) } }
        table.reloadData()
        view.needsLayout = true
        table.deselectAll(nil)
        empty.isHidden = !rows.isEmpty
        empty.stringValue = filter.stringValue.isEmpty ? "No recent projects yet" : "No matching projects or worktrees"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .project = rows[row] { return 36 }; return 56 }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .project = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .workspace(let entry) = rows[row] { return entry.root != current && available(entry.root) }
        return false
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .project(let project):
            let label = Theme.label("  " + project.root.lastPathComponent, size: 11, color: Theme.muted, weight: .semibold)
            label.toolTip = project.root.path
            return label
        case .workspace(let entry):
            let cell = HistoryCell()
            let exists = available(entry.root)
            let suffix = entry.root == current ? " · Current" : exists ? "" : " · Unavailable"
            cell.title.stringValue = entry.title + suffix
            cell.title.textColor = entry.root == current ? Theme.accent : exists ? Theme.text : Theme.muted
            cell.path.stringValue = entry.root.path
            cell.toolTip = entry.root.path
            return cell
        }
    }
    @objc private func filterChanged() { applyFilter() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onDismiss?(); return true }
        guard commandSelector == #selector(NSResponder.moveDown(_:)) || commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if let index = rows.indices.first(where: { tableView(table, shouldSelectRow: $0) }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            table.scrollRowToVisible(index)
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { choose() }
            else { view.window?.makeFirstResponder(table) }
        }
        return true
    }
    @objc private func choose() {
        guard rows.indices.contains(table.selectedRow), case .workspace(let entry) = rows[table.selectedRow], entry.root != current, available(entry.root) else { return }
        onChoose?(entry.root)
    }
}

final class HistoryTableView: NSTableView {
    var onEscape: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, delegate?.tableView?(self, shouldSelectRow: row) != false else { return }
        super.mouseDown(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { if let action { NSApp.sendAction(action, to: target, from: self) } }
        else if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}

private final class HistoryCell: NSTableCellView {
    let title = Theme.label("", size: 13, weight: .medium)
    let path = Theme.label("", size: 11, color: Theme.muted)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingMiddle
        path.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(title, path)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), title.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor), path.trailingAnchor.constraint(equalTo: title.trailingAnchor), path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
