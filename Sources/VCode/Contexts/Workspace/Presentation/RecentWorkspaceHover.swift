import AppKit

/// A nonactivating detail card anchored beside the compact workspace rail.
final class RecentWorkspaceHover {
    private(set) var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var monitor: Any?

    func schedule(_ entry: RecentWorkspace, current: Bool, available: Bool, beside anchor: NSView, onShow: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, anchor.window != nil, !anchor.visibleRect.isEmpty else { return }
            onShow()
            self.show(entry, current: current, available: available, beside: anchor)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func leave() {
        dismiss()
    }

    func dismiss() {
        pending?.cancel(); pending = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let panel { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
        panel = nil
    }

    func show(_ entry: RecentWorkspace, current: Bool, available: Bool, beside anchor: NSView) {
        dismiss()
        guard let window = anchor.window else { return }
        let bounds = window.convertToScreen(window.contentLayoutRect).intersection(window.screen?.visibleFrame ?? window.frame).insetBy(dx: 10, dy: 10)
        guard bounds.width > 100, bounds.height > 100 else { return }
        let width = min(340, bounds.width)
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 160))
        let card = FloatingSurface()
        let name = Theme.label(entry.root.lastPathComponent, size: 14, color: Theme.text, weight: .semibold)
        let metadata = Theme.label((entry.projectName == entry.root.lastPathComponent ? "" : entry.projectName + "  ·  ") + (entry.branch ?? "Folder"), size: 11, color: Theme.accent)
        let path = NSTextField(wrappingLabelWithString: entry.root.path)
        path.font = .systemFont(ofSize: 11); path.textColor = Theme.muted; path.lineBreakMode = .byCharWrapping
        let status = Theme.label(current ? "Current workspace" : available ? "" : "Folder unavailable", size: 10, color: Theme.muted)
        let pathHeight = 4 + ceil((entry.root.path as NSString).boundingRect(with: NSSize(width: width - 32, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: path.font!]).height)
        let statusHeight: CGFloat = status.stringValue.isEmpty ? 0 : 14
        let height = min(bounds.height, max(112, 85 + pathHeight + statusHeight))
        surface.frame.size.height = height
        surface.add(card); Theme.pin(card, to: surface)
        card.add(name, metadata, path, status)
        for label in [name, metadata, path, status] { label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), name.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16), name.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            metadata.leadingAnchor.constraint(equalTo: name.leadingAnchor), metadata.trailingAnchor.constraint(equalTo: name.trailingAnchor), metadata.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 5),
            path.leadingAnchor.constraint(equalTo: name.leadingAnchor), path.trailingAnchor.constraint(equalTo: name.trailingAnchor), path.topAnchor.constraint(equalTo: metadata.bottomAnchor, constant: 12),
            status.leadingAnchor.constraint(equalTo: name.leadingAnchor), status.trailingAnchor.constraint(equalTo: name.trailingAnchor), status.topAnchor.constraint(equalTo: path.bottomAnchor, constant: 8), status.heightAnchor.constraint(equalToConstant: statusHeight),
            status.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -12)
        ])
        let rect = window.convertToScreen(anchor.convert(anchor.visibleRect, to: nil))
        let x = min(max(bounds.minX, rect.maxX + 12), bounds.maxX - width)
        let y = min(max(bounds.minY, rect.maxY - height), bounds.maxY - height)
        let panel = NSPanel(contentRect: NSRect(x: x, y: y, width: width, height: height), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = surface; panel.backgroundColor = .clear; panel.isOpaque = false
        panel.hasShadow = true; panel.hidesOnDeactivate = true; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true; panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        panel.setAccessibilityLabel("Recent workspace details")
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel; panel.orderFront(nil); surface.layoutSubtreeIfNeeded()
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.dismiss() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.dismiss() })
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            if event.window !== self?.panel || (event.type == .keyDown && event.keyCode == 53) { self?.dismiss() }
            return event
        }
    }

    deinit { dismiss() }
}
