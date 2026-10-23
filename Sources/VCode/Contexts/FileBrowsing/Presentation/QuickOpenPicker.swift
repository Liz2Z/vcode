import AppKit

final class QuickOpenPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let filter = NSSearchField()
    let table = ResultTableView()
    let summary = Theme.label("", size: 11, color: Theme.muted)
    private(set) var rows: [String] = []
    var onChoose: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    private let scroll = NSScrollView()
    private var files: [String], recent: [String]
    private let queue = DispatchQueue(label: "dev.vcode.quick-open", qos: .userInitiated)
    private var token = UUID()
    // Accessed only on queue, so rapid initial queries share one file index.
    private var indexedPaths: [String] = []
    private var cachedIndex: QuickOpenIndex?

    init(paths: [String], recent: [String]) {
        files = paths; self.recent = recent
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() {
        view = FloatingSurface()
        filter.placeholderString = "Open file by name or path"
        filter.setAccessibilityLabel("Quick Open")
        filter.sendsSearchStringImmediately = true; filter.sendsWholeSearchString = false
        filter.target = self; filter.action = #selector(findFiles); filter.delegate = self
        filter.focusRingType = .none
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        table.tableColumns.first?.maxWidth = .greatestFiniteMagnitude
        table.headerView = nil; table.rowHeight = 46; table.intercellSpacing = .zero
        table.backgroundColor = Theme.floating; table.focusRingType = .none
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(choose)
        table.onEscape = { [weak self] in self?.onDismiss?() }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; Theme.compactScrollers(scroll)
        view.add(filter, summary, scroll)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: view.topAnchor, constant: 16), filter.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), filter.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), filter.heightAnchor.constraint(equalToConstant: 30),
            summary.topAnchor.constraint(equalTo: filter.bottomAnchor, constant: 8), summary.leadingAnchor.constraint(equalTo: filter.leadingAnchor), summary.trailingAnchor.constraint(equalTo: filter.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8)
        ])
        findFiles()
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }
    func update(paths: [String], recent: [String]) {
        guard paths != files || recent != self.recent else { return }
        files = paths; self.recent = recent
        if isViewLoaded { findFiles() }
    }
    @objc func findFiles() {
        token = UUID(); let request = token
        let files = self.files, recent = self.recent, query = filter.stringValue
        summary.stringValue = "Finding files…"
        queue.async { [weak self] in
            guard let self else { return }
            if self.indexedPaths != files || self.cachedIndex == nil {
                self.cachedIndex = QuickOpenIndex(paths: files); self.indexedPaths = files
            }
            guard let index = self.cachedIndex else { return }
            let rows = index.matches(query, recent: recent)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.token == request else { return }
                self.rows = rows
                self.table.reloadData()
                self.summary.stringValue = rows.isEmpty ? "No matching files" : query.isEmpty ? "Recent files first · ↑↓ select · Return open · Escape cancel" : "\(rows.count) files · ↑↓ select · Return open"
                if !rows.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); self.table.scrollRowToVisible(0) }
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let path = rows[row], cell = NSView()
        let name = Theme.label((path as NSString).lastPathComponent + (recent.contains(path) ? "  · Recent" : ""), size: 13)
        let detail = Theme.label(path, size: 11, color: Theme.muted)
        for label in [name, detail] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        cell.add(name, detail); cell.toolTip = path
        NSLayoutConstraint.activate([
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6), name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12), name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3), detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), detail.trailingAnchor.constraint(equalTo: name.trailingAnchor)
        ])
        return cell
    }
    @objc private func choose() {
        guard rows.indices.contains(table.selectedRow) else { return }
        onChoose?(rows[table.selectedRow])
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { onDismiss?(); return true }
        if commandSelector == #selector(NSResponder.moveDown(_:)) { table.moveSelection(by: 1); return true }
        if commandSelector == #selector(NSResponder.moveUp(_:)) { table.moveSelection(by: -1); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { choose(); return true }
        return false
    }
}
