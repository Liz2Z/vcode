import AppKit

final class LocationsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    enum Row {
        case file(URL, Int)
        case location(CodeLocation)
    }
    private(set) var rows: [Row] = []
    private let root: URL?
    private let onSelect: (CodeLocation) -> Void
    private let previewStore = ReferencePreviewStore()
    private let currentDocument: (url: URL, lines: [String])?
    private let table = LocationTableView()
    let summary: NSTextField
    private let empty = Theme.label("No references found", size: 13, color: Theme.muted)

    init(locations: [CodeLocation], root: URL?, references: Bool = false, currentDocument: (url: URL, lines: [String])? = nil, onSelect: @escaping (CodeLocation) -> Void) {
        self.root = root
        self.onSelect = onSelect
        self.currentDocument = currentDocument
        let unique = Array(Set(locations)).sorted {
            if $0.url.path != $1.url.path { return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            return $0.line == $1.line ? $0.character < $1.character : $0.line < $1.line
        }
        let groups = Dictionary(grouping: unique, by: \.url)
        summary = Theme.label("\(unique.count) \(references ? "references" : "definitions") · \(groups.count) files", size: 12, color: Theme.muted)
        var previousURL: URL?
        for location in unique {
            if previousURL != location.url {
                rows.append(.file(location.url, groups[location.url]?.count ?? 0))
                previousURL = location.url
            }
            rows.append(.location(location))
        }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        Theme.fill(view, Theme.background)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("location"))
        column.title = "Location"
        column.maxWidth = .greatestFiniteMagnitude
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = Theme.background
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(choose)
        table.doubleAction = #selector(choose)
        table.focusRingType = .none
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view.add(scroll, summary, empty)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), summary.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), summary.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            empty.centerXAnchor.constraint(equalTo: view.centerXAnchor), empty.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        empty.isHidden = !rows.isEmpty
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let first = rows.firstIndex(where: { if case .location = $0 { return true }; return false }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        view.window?.makeFirstResponder(table)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // The document view can resize after its column was initially fitted
        // at zero width. Keep the result column as wide as the visible table.
        if let column = table.tableColumns.first, table.bounds.width > 0,
           abs(column.width - table.bounds.width) > 1 {
            column.width = table.bounds.width
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .file = rows[row] { return 32 }; return 36 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .file = rows[row] { return false }; return true }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .file = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .file(let url, let count):
            let path = root.flatMap { url.path.hasPrefix($0.path + "/") ? String(url.path.dropFirst($0.path.count + 1)) : nil } ?? url.path
            let label = Theme.label("  \(path)  ·  \(count)", size: 11, color: Theme.muted, weight: .semibold)
            label.toolTip = url.path
            return label
        case .location(let location):
            let id = NSUserInterfaceItemIdentifier("reference")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? ReferenceCell) ?? ReferenceCell()
            cell.identifier = id
            cell.representedLocation = location
            cell.position.stringValue = "\(location.line + 1):\(location.character + 1)"
            cell.code.stringValue = "Loading preview…"
            cell.toolTip = "\(location.url.path):\(location.line + 1):\(location.character + 1)"
            if let document = currentDocument, document.url.standardizedFileURL == location.url.standardizedFileURL,
               document.lines.indices.contains(location.line) {
                cell.show(document.lines[location.line], at: location)
            } else {
                previewStore.line(at: location) { [weak cell] line in
                    guard cell?.representedLocation == location else { return }
                    cell?.show(line, at: location)
                }
            }
            return cell
        }
    }
    @objc private func choose() {
        guard rows.indices.contains(table.selectedRow), case .location(let location) = rows[table.selectedRow] else { return }
        onSelect(location)
    }
}

private final class LocationTableView: NSTableView {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            if let action { NSApp.sendAction(action, to: target, from: self) }
        } else if event.keyCode == 53 { window?.performClose(nil) }
        else { super.keyDown(with: event) }
    }
}

private final class ReferenceCell: NSView {
    var representedLocation: CodeLocation?
    let position = Theme.label("", size: 11, color: Theme.muted)
    let code = Theme.label("", size: 12)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        position.font = Theme.Code.font(size: 11)
        position.alignment = .right
        code.font = Theme.Code.font()
        code.maximumNumberOfLines = 1
        code.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        code.lineBreakMode = .byTruncatingTail
        add(position, code)
        NSLayoutConstraint.activate([
            position.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), position.widthAnchor.constraint(equalToConstant: 64), position.centerYAnchor.constraint(equalTo: centerYAnchor),
            code.leadingAnchor.constraint(equalTo: position.trailingAnchor, constant: 8), code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), code.centerYAnchor.constraint(equalTo: centerYAnchor), code.heightAnchor.constraint(equalToConstant: 22)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ line: String?, at location: CodeLocation) {
        guard let line else { code.stringValue = "Preview unavailable"; return }
        let source = line as NSString
        let column = min(location.character, source.length)
        let start = max(0, column - 60)
        let end = min(source.length, column + 160)
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let prefix = range.location > 0 ? "… " : ""
        let snippet = prefix + source.substring(with: range)
        let storage = NSTextStorage(string: snippet)
        Syntax.apply(to: storage, path: location.url.path, font: Theme.Code.font())
        // A one-line label uses cell metrics rather than editor paragraphs.
        storage.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: storage.length))
        let index = column - range.location + (prefix as NSString).length
        if let symbol = CodeTextView.identifier(in: snippet as NSString, at: index) {
            storage.addAttribute(.backgroundColor, value: Theme.accent.withAlphaComponent(0.22), range: symbol)
        }
        code.attributedStringValue = storage
        code.toolTip = line
    }
}
