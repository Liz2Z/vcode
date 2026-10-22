import AppKit

final class WorkspaceView: NSView, NSSplitViewDelegate {
    let explorer = FileTree()
    let editor = EditorView()
    let header = WorkspaceHeader()
    let navigation = WorkspaceNavigation()
    let status = WorkspaceStatus()
    private let split = WorkspaceSplitView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.fill(self, Theme.canvas)
        let sidebarContent = NSView()
        sidebarContent.add(navigation, explorer)
        let sidebar = GlassSurface(content: sidebarContent, radius: Theme.Layout.panelRadius)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor), navigation.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor), navigation.topAnchor.constraint(equalTo: sidebarContent.topAnchor), navigation.heightAnchor.constraint(equalToConstant: 40),
            explorer.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 4), explorer.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor), explorer.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor), explorer.bottomAnchor.constraint(equalTo: sidebarContent.bottomAnchor)
        ])
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(editor)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        add(header, split, status)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 56),
            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), split.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), split.topAnchor.constraint(equalTo: header.bottomAnchor), split.bottomAnchor.constraint(equalTo: status.topAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: WorkspaceSplitView.minimumSidebarWidth), editor.widthAnchor.constraint(greaterThanOrEqualToConstant: WorkspaceSplitView.minimumEditorWidth),
            status.leadingAnchor.constraint(equalTo: leadingAnchor), status.trailingAnchor.constraint(equalTo: trailingAnchor), status.bottomAnchor.constraint(equalTo: bottomAnchor), status.heightAnchor.constraint(equalToConstant: 32)
        ])
        DispatchQueue.main.async { [weak self] in self?.split.setPosition(240, ofDividerAt: 0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: WorkspaceState, changesOnly: Bool) {
        editor.setWorkspaceOpen(true)
        header.show(state)
        explorer.show(state, changesOnly: changesOnly)
        navigation.changes.toolTip = "Changes (⌘2) · \(state.changes.count) files"
        status.message.stringValue = "\(state.files.count) files  ·  \(state.changes.count) changes  ·  Read Only"
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { WorkspaceSplitView.minimumSidebarWidth }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(WorkspaceSplitView.minimumSidebarWidth, splitView.bounds.width - splitView.dividerThickness - WorkspaceSplitView.minimumEditorWidth)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.arrangedSubviews.count == 2 else { return }
        let sidebar = splitView.arrangedSubviews[0]
        let maximum = self.splitView(splitView, constrainMaxCoordinate: splitView.bounds.width, ofSubviewAt: 0)
        let width = min(maximum, max(WorkspaceSplitView.minimumSidebarWidth, oldSize.width == 0 ? 240 : sidebar.frame.width))
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
        editor.frame = NSRect(x: width + splitView.dividerThickness, y: 0, width: max(0, splitView.bounds.width - width - splitView.dividerThickness), height: splitView.bounds.height)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        (notification.object as? WorkspaceSplitView)?.updateTrackingAreas()
    }
}
