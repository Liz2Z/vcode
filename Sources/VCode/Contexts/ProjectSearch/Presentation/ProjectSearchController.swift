import AppKit

final class ProjectSearchController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    enum Row { case file(String, Int), match(ProjectSearchMatch) }
    let query = NSSearchField()
    let exclusions = NSTextField()
    let caseButton = Theme.actionButton("Aa"), wordButton = Theme.actionButton("ab"), regexButton = Theme.actionButton(".*")
    let status = NSTextField(wrappingLabelWithString: "Search the project")
    let table = ResultTableView()
    private let scroll = NSScrollView()
    private let backend: RipgrepSearch
    private var task: ProjectSearchTask?
    private var pending: DispatchWorkItem?
    private var token = UUID()
    private(set) var root: URL?
    private var paths: [String] = []
    private(set) var rows: [Row] = []
    private(set) var isSearching = false
    private var active = false
    var onChoose: ((URL, ProjectSearchMatch) -> Void)?
    var onDismiss: (() -> Void)?

    init(backend: RipgrepSearch = RipgrepSearch()) { self.backend = backend; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    deinit { pending?.cancel(); task?.cancel() }

    override func loadView() {
        view = NSView()
        let title = Theme.label("SEARCH", size: 10, color: Theme.muted, weight: .semibold)
        query.placeholderString = "Search in project"
        query.setAccessibilityLabel("Search in project")
        query.sendsSearchStringImmediately = true; query.sendsWholeSearchString = false
        query.target = self; query.action = #selector(queryChanged); query.delegate = self; query.focusRingType = .none
        let options = NSStackView(views: [caseButton, wordButton, regexButton])
        options.orientation = .horizontal; options.spacing = 4
        for (button, label) in [(caseButton, "Match case"), (wordButton, "Match whole word"), (regexButton, "Use regular expression")] {
            button.toolTip = label; button.setAccessibilityLabel(label)
            button.target = self; button.action = #selector(toggleOption(_:))
            button.horizontalPadding = 6
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        let excludeLabel = Theme.label("Exclude folders", size: 11, color: Theme.muted)
        exclusions.placeholderString = "tests, dist, src/generated"
        exclusions.setAccessibilityLabel("Exclude folders")
        exclusions.font = .systemFont(ofSize: 12); exclusions.focusRingType = .none; exclusions.delegate = self
        exclusions.toolTip = "Comma-separated relative folders or folder patterns; a bare name excludes that folder at any depth."
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("search-result")))
        table.tableColumns.first?.maxWidth = .greatestFiniteMagnitude
        table.headerView = nil; table.intercellSpacing = .zero; table.backgroundColor = .clear; table.focusRingType = .none
        table.dataSource = self; table.delegate = self; table.target = self; table.action = #selector(choose)
        table.onEscape = { [weak self] in self?.onDismiss?() }
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.drawsBackground = false
        Theme.compactScrollers(scroll)
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.muted
        status.maximumNumberOfLines = 3; status.setAccessibilityLabel("Search status")
        view.add(title, query, options, excludeLabel, exclusions, status, scroll)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 10), title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            query.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), query.leadingAnchor.constraint(equalTo: title.leadingAnchor), query.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16), query.heightAnchor.constraint(equalToConstant: 28),
            options.topAnchor.constraint(equalTo: query.bottomAnchor, constant: 6), options.leadingAnchor.constraint(equalTo: query.leadingAnchor),
            excludeLabel.topAnchor.constraint(equalTo: options.bottomAnchor, constant: 10), excludeLabel.leadingAnchor.constraint(equalTo: query.leadingAnchor),
            exclusions.topAnchor.constraint(equalTo: excludeLabel.bottomAnchor, constant: 5), exclusions.leadingAnchor.constraint(equalTo: query.leadingAnchor), exclusions.trailingAnchor.constraint(equalTo: query.trailingAnchor), exclusions.heightAnchor.constraint(equalToConstant: 26),
            status.topAnchor.constraint(equalTo: exclusions.bottomAnchor, constant: 10), status.leadingAnchor.constraint(equalTo: query.leadingAnchor), status.trailingAnchor.constraint(equalTo: query.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8), scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        table.tableColumns.first?.width = max(0, scroll.contentSize.width)
    }
    func setWorkspace(root: URL, paths: [String]) {
        _ = view
        if self.root != root { cancel(); query.stringValue = ""; rows = []; table.reloadData(); status.stringValue = "Search the project" }
        self.root = root; self.paths = paths
        if active && !query.stringValue.isEmpty { scheduleSearch() }
    }
    func setActive(_ active: Bool) {
        self.active = active
        query.isEnabled = active; exclusions.isEnabled = active; table.isEnabled = active
        for button in [caseButton, wordButton, regexButton] { button.isEnabled = active }
        if active { scheduleSearch(); view.window?.makeFirstResponder(query) }
        else { cancel() }
    }
    func cancel() {
        token = UUID(); pending?.cancel(); pending = nil; task?.cancel(); task = nil; isSearching = false
    }
    @objc private func queryChanged() { scheduleSearch() }
    func controlTextDidChange(_ obj: Notification) { scheduleSearch() }
    @objc private func toggleOption(_ button: FeedbackButton) {
        button.isSelected.toggle(); button.setAccessibilityValue(button.isSelected ? 1 : 0); scheduleSearch()
    }
    private func scheduleSearch() {
        cancel(); rows = []; table.reloadData()
        status.textColor = Theme.muted; status.toolTip = nil
        guard active, root != nil, !query.stringValue.isEmpty else { status.stringValue = "Search the project · Text files up to 4 MiB"; return }
        isSearching = true; status.stringValue = "Searching…"
        let request = token
        let work = DispatchWorkItem { [weak self] in self?.performSearch(request: request) }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func performSearch(request: UUID) {
        guard token == request, active, let root else { return }
        let options = ProjectSearchQuery(text: query.stringValue, caseSensitive: caseButton.isSelected, wholeWord: wordButton.isSelected, regularExpression: regexButton.isSelected, excludedFolders: exclusions.stringValue)
        task = backend.search(root: root, paths: paths, query: options) { [weak self] result in
            guard let self, self.token == request, self.root == root, self.active else { return }
            self.isSearching = false
            switch result {
            case .failure(let error):
                let message = error.localizedDescription
                self.status.stringValue = "Search error: " + (message.split(separator: "\n").last.map(String.init) ?? message)
                self.status.toolTip = message; self.status.textColor = Theme.red
            case .success(let results):
                self.rows = []; var previous: String?
                let counts = Dictionary(grouping: results.matches, by: \.path).mapValues { $0.reduce(0) { $0 + $1.ranges.count } }
                for match in results.matches {
                    if previous != match.path { self.rows.append(.file(match.path, counts[match.path] ?? 0)); previous = match.path }
                    self.rows.append(.match(match))
                }
                let count = results.matches.reduce(0) { $0 + $1.ranges.count }
                self.status.stringValue = results.matches.isEmpty ? "No results" : "\(count) matches · \(counts.count) files"
                if results.limited { self.status.stringValue += " · First 2,000 lines; narrow the search" }
                if results.skippedFiles > 0 { self.status.stringValue += " · \(results.skippedFiles) unavailable or large files skipped" }
                if let warning = results.warning { self.status.stringValue += " · " + warning }
                self.status.toolTip = self.status.stringValue
                self.status.textColor = results.warning == nil ? Theme.muted : Theme.accent
                self.table.reloadData()
            }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { if case .file = rows[row] { return 30 }; return 32 }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { if case .file = rows[row] { return true }; return false }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { if case .file = rows[row] { return false }; return true }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SelectionRowView() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .file(let path, let count):
            let label = Theme.label("\(path) · \(count)", size: 11, color: Theme.muted, weight: .semibold)
            label.toolTip = path; return label
        case .match(let match):
            let label = Theme.label("", size: 12)
            let source = match.text as NSString, start = max(0, match.character - 24)
            let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: min(start, source.length), length: min(180, max(0, source.length - start))))
            let prefix = "\(match.line + 1): " + (range.location > 0 ? "… " : "")
            let text = NSMutableAttributedString(string: prefix + source.substring(with: range), attributes: [.font: Theme.Code.font(size: 11), .foregroundColor: Theme.text])
            for hit in match.ranges {
                if hit.location >= NSMaxRange(range) { break }
                let overlap = NSIntersectionRange(hit, range)
                if overlap.length > 0 { text.addAttribute(.backgroundColor, value: Theme.accent.withAlphaComponent(0.25), range: NSRange(location: (prefix as NSString).length + overlap.location - range.location, length: overlap.length)) }
            }
            label.attributedStringValue = text; label.lineBreakMode = .byTruncatingTail
            label.toolTip = "\(match.path):\(match.line + 1):\(match.character + 1)\n\(match.text)"
            return label
        }
    }
    @objc private func choose() {
        guard let root, rows.indices.contains(table.selectedRow), case .match(let match) = rows[table.selectedRow] else { return }
        onChoose?(root, match)
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onDismiss?(); return true }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if isSearching { return true }
            if table.selectedRow < 0 { table.moveSelection(by: 1) }
            choose(); return true
        }
        if selector == #selector(NSResponder.moveDown(_:)) { table.moveSelection(by: 1); return true }
        if selector == #selector(NSResponder.moveUp(_:)) { table.moveSelection(by: -1); return true }
        return false
    }
}
