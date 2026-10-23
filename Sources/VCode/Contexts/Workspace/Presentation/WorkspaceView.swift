import AppKit

final class WorkspaceView: NSView, NSSplitViewDelegate {
    let explorer = FileTree()
    let editorGroups = EditorGroupsView()
    var editor: EditorView { editorGroups.activeEditor }
    let header = WorkspaceHeader()
    let navigation = WorkspaceNavigation()
    let status = WorkspaceStatus()
    let searchHost = NSView()
    let openNotice = ExternalOpenNotice()
    private let split = WorkspaceSplitView()
    private var editorMinimumWidth: NSLayoutConstraint!
    private weak var noticePreviousFocus: NSResponder?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.fill(self, Theme.canvas)
        let sidebarContent = NSView()
        sidebarContent.add(navigation, explorer, searchHost)
        searchHost.isHidden = true
        let sidebar = GlassSurface(content: sidebarContent, radius: Theme.Layout.panelRadius)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor), navigation.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor), navigation.topAnchor.constraint(equalTo: sidebarContent.topAnchor), navigation.heightAnchor.constraint(equalToConstant: 40),
            explorer.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 4), explorer.leadingAnchor.constraint(equalTo: sidebarContent.leadingAnchor), explorer.trailingAnchor.constraint(equalTo: sidebarContent.trailingAnchor), explorer.bottomAnchor.constraint(equalTo: sidebarContent.bottomAnchor),
            searchHost.topAnchor.constraint(equalTo: explorer.topAnchor), searchHost.leadingAnchor.constraint(equalTo: explorer.leadingAnchor), searchHost.trailingAnchor.constraint(equalTo: explorer.trailingAnchor), searchHost.bottomAnchor.constraint(equalTo: explorer.bottomAnchor)
        ])
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(editorGroups)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        add(header, split, status)
        editorGroups.add(openNotice)
        Theme.pin(openNotice, to: editorGroups)
        openNotice.isHidden = true
        editorMinimumWidth = editorGroups.widthAnchor.constraint(greaterThanOrEqualToConstant: editorGroups.minimumWidth)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor), header.leadingAnchor.constraint(equalTo: leadingAnchor), header.trailingAnchor.constraint(equalTo: trailingAnchor), header.heightAnchor.constraint(equalToConstant: 56),
            split.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), split.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), split.topAnchor.constraint(equalTo: header.bottomAnchor), split.bottomAnchor.constraint(equalTo: status.topAnchor),
            sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: WorkspaceSplitView.minimumSidebarWidth), editorMinimumWidth,
            status.leadingAnchor.constraint(equalTo: leadingAnchor), status.trailingAnchor.constraint(equalTo: trailingAnchor), status.bottomAnchor.constraint(equalTo: bottomAnchor), status.heightAnchor.constraint(equalToConstant: 32)
        ])
        editorGroups.onLayoutChanged = { [weak self] in
            guard let self else { return }
            self.editorMinimumWidth.constant = self.editorGroups.minimumWidth
            let maximum = self.splitView(self.split, constrainMaxCoordinate: self.split.bounds.width, ofSubviewAt: 0)
            self.split.setPosition(min(self.split.arrangedSubviews[0].frame.width, maximum), ofDividerAt: 0)
            self.split.adjustSubviews()
        }
        DispatchQueue.main.async { [weak self] in self?.split.setPosition(240, ofDividerAt: 0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var sidebarWidth: Double { Double(split.arrangedSubviews[0].frame.width) }

    func showOpenNotice(_ failures: [ExternalOpenNotice.Failure]) {
        if openNotice.isHidden { noticePreviousFocus = window?.firstResponder }
        openNotice.show(failures, empty: editorGroups.editors.allSatisfy { $0.activePath == nil })
        openNotice.isHidden = false
        if window?.attachedSheet == nil { window?.makeFirstResponder(openNotice) }
    }

    func dismissOpenNotice() {
        guard !openNotice.isHidden else { return }
        let restoreFocus = (window?.firstResponder as? NSView).map { $0 === openNotice || $0.isDescendant(of: openNotice) } ?? false
        openNotice.isHidden = true
        if restoreFocus {
            if let previous = noticePreviousFocus as? NSView, previous.window === window, !previous.isHiddenOrHasHiddenAncestor {
                window?.makeFirstResponder(previous)
            } else { editorGroups.activate(editor, focus: true) }
        }
        noticePreviousFocus = nil
    }

    func restoreSidebarWidth(_ width: Double) {
        guard width.isFinite else { return }
        layoutSubtreeIfNeeded()
        let maximum = splitView(split, constrainMaxCoordinate: split.bounds.width, ofSubviewAt: 0)
        split.setPosition(min(maximum, max(WorkspaceSplitView.minimumSidebarWidth, width)), ofDividerAt: 0)
    }

    func showSearch(_ visible: Bool) {
        searchHost.isHidden = !visible; explorer.isHidden = visible
        if visible { navigation.select(changes: nil) }
    }

    func show(_ state: WorkspaceState, changesOnly: Bool) {
        editorGroups.setWorkspaceOpen(true)
        navigation.select(changes: searchHost.isHidden ? changesOnly : nil)
        navigation.search.isEnabled = true
        header.show(state)
        explorer.show(state, changesOnly: changesOnly)
        navigation.changes.toolTip = "Changes (⌘2) · \(state.changes.count) files"
        status.message.stringValue = "\(state.files.count) files  ·  \(state.changes.count) changes  ·  Read Only"
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { WorkspaceSplitView.minimumSidebarWidth }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(WorkspaceSplitView.minimumSidebarWidth, splitView.bounds.width - splitView.dividerThickness - editorGroups.minimumWidth)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView.arrangedSubviews.count == 2 else { return }
        let sidebar = splitView.arrangedSubviews[0]
        let maximum = self.splitView(splitView, constrainMaxCoordinate: splitView.bounds.width, ofSubviewAt: 0)
        let width = min(maximum, max(WorkspaceSplitView.minimumSidebarWidth, oldSize.width == 0 ? 240 : sidebar.frame.width))
        sidebar.frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
        editorGroups.frame = NSRect(x: width + splitView.dividerThickness, y: 0, width: max(0, splitView.bounds.width - width - splitView.dividerThickness), height: splitView.bounds.height)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        (notification.object as? WorkspaceSplitView)?.updateTrackingAreas()
    }
}
