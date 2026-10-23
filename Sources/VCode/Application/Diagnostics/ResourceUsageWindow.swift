import AppKit

final class ResourceUsageWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let monitor = ResourceUsageMonitor()
    private let cpu = Theme.label("—", size: 26, weight: .medium)
    private let memory = Theme.label("—", size: 26, weight: .medium)
    private let threads = Theme.label("—", size: 26, weight: .medium)
    private let status = Theme.label("Measuring…", size: 11, color: Theme.muted)
    private let table = NSTableView()
    private var rows: [ProcessResourceUsage] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 430), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Resource Usage"
        window.minSize = NSSize(width: 600, height: 350)
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.background
        super.init(window: window)
        window.delegate = self
        window.center()
        makeContent()
        monitor.onUpdate = { [weak self] in self?.render($0) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        if !monitor.isRunning {
            rows = []
            table.reloadData()
            cpu.stringValue = "—"; memory.stringValue = "—"; threads.stringValue = "—"
            status.stringValue = "Measuring…"
        }
        super.showWindow(sender)
        window?.deminiaturize(sender)
        window?.makeKeyAndOrderFront(sender)
        monitor.start()
    }
    func windowWillClose(_ notification: Notification) { monitor.stop() }

    private func makeContent() {
        guard let content = window?.contentView else { return }
        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 16
        for (title, value) in [("CPU", cpu), ("Memory footprint", memory), ("Threads", threads)] {
            let stack = NSStackView(views: [Theme.label(title, size: 12, color: Theme.muted), value])
            stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
            value.font = .monospacedDigitSystemFont(ofSize: 26, weight: .medium)
            metrics.addArrangedSubview(stack)
        }
        cpu.textColor = Theme.accent
        let scope = Theme.label("VCode and its child processes, including language services", size: 12, color: Theme.muted)
        let note = Theme.label("Updates every second · 100% CPU = one core", size: 11, color: Theme.muted)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        Theme.compactScrollers(scroll)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        table.backgroundColor = Theme.background
        table.rowHeight = 30
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("process", "Process / PID", 245.0), ("cpu", "CPU", 75.0), ("memory", "Memory", 110.0), ("threads", "Threads", 70.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width; column.minWidth = id == "process" ? 130 : width
            column.resizingMask = id == "process" ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self; table.delegate = self
        scroll.documentView = table
        content.add(metrics, scope, scroll, note, status)
        NSLayoutConstraint.activate([
            metrics.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            metrics.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            metrics.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scope.topAnchor.constraint(equalTo: metrics.bottomAnchor, constant: 16),
            scope.leadingAnchor.constraint(equalTo: metrics.leadingAnchor),
            scope.trailingAnchor.constraint(equalTo: metrics.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 20),
            scroll.leadingAnchor.constraint(equalTo: metrics.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: metrics.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -16),
            note.leadingAnchor.constraint(equalTo: metrics.leadingAnchor),
            note.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: metrics.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: metrics.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func render(_ snapshot: ResourceUsageSnapshot) {
        rows = snapshot.processes
        cpu.stringValue = percent(snapshot.cpu)
        memory.stringValue = rows.isEmpty ? "—" : bytes(snapshot.memory)
        threads.stringValue = snapshot.threads.map(String.init) ?? "—"
        let time = DateFormatter.localizedString(from: snapshot.updatedAt, dateStyle: .none, timeStyle: .medium)
        status.stringValue = "\(rows.count) processes · Updated \(time)" + (snapshot.unavailable > 0 ? " · \(snapshot.unavailable) unavailable; totals are partial" : "")
        table.reloadData()
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    private func bytes(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory) }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let id = tableColumn?.identifier.rawValue else { return nil }
        let value = rows[row]
        let text: String
        switch id {
        case "cpu": text = percent(value.cpu)
        case "memory": text = bytes(value.sample.memory)
        case "threads": text = value.sample.threads.map(String.init) ?? "—"
        default: text = "\(value.sample.name) · \(value.sample.pid)"
        }
        let cell = NSTableCellView()
        let field = Theme.label(text)
        cell.add(field); cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
