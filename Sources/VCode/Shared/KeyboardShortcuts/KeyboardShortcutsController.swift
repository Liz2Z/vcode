import AppKit

final class KeyboardShortcutsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case group(String), entry(KeyboardShortcutEntry) }
    let filter = Theme.searchField()
    let table = NSTableView()
    let summary = Theme.label("", size: 11, color: Theme.muted)
    private let scroll = NSScrollView()
    private let entries: [KeyboardShortcutEntry]
    private(set) var rows: [Row] = []
    var onDismiss: (() -> Void)?

    init(entries: [KeyboardShortcutEntry]) {
        self.entries = entries
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = FloatingSurface()
        let title = Theme.label("Keyboard Shortcuts", size: 16, weight: .semibold)
        let hint = Theme.label("\(KeyboardShortcutCatalog.chord) · Press the two shortcuts in sequence · Esc closes", size: 11, color: Theme.muted)
        let close = Theme.button("xmark", tooltip: "Close Keyboard Shortcuts (Esc)", target: self, action: #selector(dismissList))
        close.feedbackRadius = 4
        filter.placeholderString = "Search commands or shortcuts"
        filter.setAccessibilityLabel("Search keyboard shortcuts")
        filter.sendsSearchStringImmediately = true; filter.sendsWholeSearchString = false
        filter.target = self; filter.action = #selector(filterChanged); filter.delegate = self
        filter.focusRingType = .none
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.headerView = nil; table.intercellSpacing = .zero
        table.style = .plain
        table.floatsGroupRows = false
        table.backgroundColor = Theme.floating; table.focusRingType = .none
        table.selectionHighlightStyle = .none
        table.dataSource = self; table.delegate = self
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; Theme.compactScrollers(scroll)
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        view.add(title, hint, close, filter, summary, scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), close.centerYAnchor.constraint(equalTo: title.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24), title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -12),
            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8), hint.leadingAnchor.constraint(equalTo: title.leadingAnchor), hint.trailingAnchor.constraint(equalTo: close.trailingAnchor),
            filter.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12), filter.leadingAnchor.constraint(equalTo: title.leadingAnchor), filter.trailingAnchor.constraint(equalTo: close.trailingAnchor), filter.heightAnchor.constraint(equalToConstant: 30),
            summary.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8), summary.leadingAnchor.constraint(equalTo: title.leadingAnchor), summary.trailingAnchor.constraint(equalTo: filter.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
        filterChanged()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }

    @objc func filterChanged() {
        let found = entries.filter { $0.matches(filter.stringValue) }
        rows = []
        var group: String?
        for entry in found {
            if entry.group != group { rows.append(.group(entry.group)); group = entry.group }
            rows.append(.entry(entry))
        }
        table.reloadData()
        if !rows.isEmpty { table.scrollRowToVisible(0) }
        summary.stringValue = found.isEmpty ? "No matching shortcuts" : "\(found.count) \(found.count == 1 ? "action" : "actions") · Keyboard and mouse shortcuts"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .group = rows[row] { return 30 }; return 48 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .group(let group):
            let cell = NSView(), label = Theme.label(group, size: 11, color: Theme.muted, weight: .semibold)
            cell.add(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16), label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -16), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        case .entry(let entry):
            let cell = NSView()
            let title = Theme.label(entry.title, size: 13)
            let detail = Theme.label(entry.detail, size: 11, color: Theme.muted)
            let keys = Theme.label(entry.keys, size: 12, color: Theme.accent, weight: .medium)
            keys.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
            keys.alignment = .right
            cell.toolTip = [entry.title, entry.keys, entry.detail].filter { !$0.isEmpty }.joined(separator: " · ")
            cell.add(title, detail, keys)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 16), title.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -16),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: entry.detail.isEmpty ? 14 : 6),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor), detail.trailingAnchor.constraint(lessThanOrEqualTo: keys.leadingAnchor, constant: -16), detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
                keys.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -16), keys.centerYAnchor.constraint(equalTo: cell.centerYAnchor), keys.widthAnchor.constraint(equalToConstant: 160)
            ])
            return cell
        }
    }

    @objc private func dismissList() { onDismiss?() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onDismiss?(); return true }
        return false
    }
}
