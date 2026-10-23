import AppKit

final class GitDestinationPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Kind { case branches, worktrees }
    private struct Option {
        let title: String
        let detail: String
        let destination: GitDestination
        let current: Bool
        let available: Bool
        let action: String
    }
    var onChoose: ((GitDestination) -> Void)?
    var onRefresh: (() -> Void)?
    let kind: Kind
    let filter = NSSearchField()
    let table = NSTableView()
    let action = Theme.actionButton("Switch", symbol: "arrow.right")
    private let refresh = Theme.button("arrow.clockwise", tooltip: "Refresh list", target: nil, action: nil)
    private let hint = Theme.label("Loading…", size: 11, color: Theme.muted)
    private let empty = Theme.label("Loading…", size: 12, color: Theme.muted)
    private var allOptions: [Option] = []
    private var options: [Option] = []
    private var busy = false

    init(kind: Kind) { self.kind = kind; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 440))
        Theme.fill(view, Theme.background)
        let title = Theme.label(kind == .branches ? "Local branches" : "Worktrees", size: 15, weight: .semibold)
        filter.placeholderString = kind == .branches ? "Filter branches" : "Filter by folder, path or branch"
        filter.font = .systemFont(ofSize: 12)
        filter.focusRingType = .none
        filter.sendsSearchStringImmediately = true
        filter.sendsWholeSearchString = false
        filter.target = self; filter.action = #selector(filterChanged)
        refresh.target = self; refresh.action = #selector(refreshList)
        table.headerView = nil
        table.backgroundColor = Theme.background
        table.rowHeight = 54
        table.intercellSpacing = .zero
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(choose)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        Theme.compactScrollers(scroll)
        scroll.drawsBackground = false
        empty.alignment = .center
        hint.maximumNumberOfLines = 3
        action.target = self; action.action = #selector(choose)
        action.isSelected = true
        action.isEnabled = false
        view.add(title, refresh, filter, scroll, empty, hint, action)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            refresh.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), refresh.centerYAnchor.constraint(equalTo: title.centerYAnchor), refresh.widthAnchor.constraint(equalToConstant: 28), refresh.heightAnchor.constraint(equalToConstant: 28),
            filter.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12), filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), filter.heightAnchor.constraint(equalToConstant: 28),
            scroll.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor), empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), hint.bottomAnchor.constraint(equalTo: action.topAnchor, constant: -8), hint.heightAnchor.constraint(equalToConstant: 42),
            action.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), action.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16), action.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    func show(_ destinations: GitDestinations) {
        _ = view
        if kind == .branches {
            allOptions = destinations.branches.map { branch in
                let occupied = branch.worktree.flatMap { root in destinations.worktrees.first { $0.root == root } }
                let elsewhere = branch.worktree != nil && branch.worktree != destinations.root
                return Option(title: branch.name, detail: elsewhere ? "Open worktree · \(branch.worktree!.path)" : "Local branch", destination: .branch(branch.name), current: destinations.currentBranch == branch.name, available: !elsewhere || occupied?.isAvailable == true, action: elsewhere ? "Open Worktree" : "Switch Branch")
            }
        } else {
            allOptions = destinations.worktrees.map { worktree in
                let branch = worktree.branch ?? (worktree.isBare ? "Bare" : "Detached · \(worktree.head.prefix(8))")
                let note = worktree.note.map { " · " + $0 } ?? ""
                return Option(title: "\(worktree.root.lastPathComponent) · \(branch)\(note)", detail: worktree.root.path, destination: .worktree(worktree.root), current: worktree.root == destinations.root, available: worktree.isAvailable, action: "Open Worktree")
            }
        }
        allOptions.sort { $0.current != $1.current ? $0.current : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        setBusy(false)
        applyFilter()
    }

    func setBusy(_ value: Bool) {
        _ = view
        busy = value
        filter.isEnabled = !value
        table.isEnabled = !value
        refresh.isEnabled = !value
        hint.textColor = Theme.muted
        hint.toolTip = nil
        hint.stringValue = value ? "Switching…" : kind == .branches ? "Git keeps compatible local edits. Conflicting changes stop the switch." : "Each worktree keeps its own files and uncommitted changes."
        updateAction()
    }

    func showError(_ error: Error) {
        setBusy(false)
        hint.textColor = Theme.red
        hint.stringValue = error.localizedDescription
        hint.toolTip = error.localizedDescription
        if allOptions.isEmpty { empty.stringValue = "Could not load the list. Use Refresh to retry." }
    }

    private func applyFilter() {
        let query = filter.stringValue
        options = allOptions.filter { query.isEmpty || ($0.title + " " + $0.detail).localizedCaseInsensitiveContains(query) }
        table.reloadData()
        if let row = options.firstIndex(where: { !$0.current && $0.available }) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { table.deselectAll(nil) }
        empty.isHidden = !options.isEmpty
        empty.stringValue = query.isEmpty ? (kind == .branches ? "No local branches yet" : "No worktrees found") : "No matching results"
        updateAction()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { options.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let option = options[row]
        let cell = DestinationCell()
        cell.title.stringValue = option.title + (option.current ? " · Current" : "")
        cell.title.textColor = option.current ? Theme.accent : option.available ? Theme.text : Theme.muted
        cell.detail.stringValue = option.detail
        cell.toolTip = option.detail
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateAction() }
    private func updateAction() {
        guard options.indices.contains(table.selectedRow) else { action.isEnabled = false; return }
        let option = options[table.selectedRow]
        action.title = option.action
        action.isEnabled = !busy && !option.current && option.available
    }
    @objc private func filterChanged() { applyFilter() }
    @objc private func refreshList() { empty.stringValue = "Loading…"; onRefresh?() }
    @objc private func choose() {
        guard !busy, options.indices.contains(table.selectedRow) else { return }
        let option = options[table.selectedRow]
        guard option.available, !option.current else { return }
        onChoose?(option.destination)
    }
}

private final class DestinationCell: NSTableCellView {
    let title = Theme.label("", size: 13, weight: .medium)
    let detail = Theme.label("", size: 11, color: Theme.muted)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        add(title, detail)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), title.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(equalTo: title.trailingAnchor), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
