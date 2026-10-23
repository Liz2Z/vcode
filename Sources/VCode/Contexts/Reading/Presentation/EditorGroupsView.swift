import AppKit

final class EditorGroupsView: NSView, NSSplitViewDelegate {
    private(set) var editors: [EditorView]
    private(set) var activeEditor: EditorView
    var onEditorAdded: ((EditorView) -> Void)?
    var onEditorRemoved: ((EditorView) -> Void)?
    var onActiveChanged: ((EditorView) -> Void)?
    var onSplitDocument: ((ReadingDocument, EditorView) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var minimumWidth: CGFloat { CGFloat(editors.count) * 220 + (editors.count == 2 ? split.dividerThickness : 0) }
    private let split = ResizableSplitView()
    private var workspaceOpen = false
    private var inputMonitor: Any?

    override init(frame frameRect: NSRect) {
        let editor = EditorView()
        editors = [editor]
        activeEditor = editor
        super.init(frame: frameRect)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(editor)
        add(split)
        Theme.pin(split, to: self)
        configure(editor)
        updateGroups()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let inputMonitor { NSEvent.removeMonitor(inputMonitor) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        guard let window else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            if event.type == .keyDown {
                if let view = window.firstResponder as? NSView,
                   let editor = self.editors.first(where: { view === $0 || view.isDescendant(of: $0) }) { self.activate(editor) }
            } else {
                // Floating content belongs to the group host, not the reading
                // split. Clicking it must not switch the active editor below it.
                guard let parent = self.superview, let hit = self.hitTest(parent.convert(event.locationInWindow, from: nil)),
                      hit === self.split || hit.isDescendant(of: self.split) else { return event }
                let point = self.split.convert(event.locationInWindow, from: nil)
                if let editor = self.editors.first(where: { $0.frame.contains(point) }) { self.activate(editor) }
            }
            return event
        }
    }

    func setWorkspaceOpen(_ open: Bool) {
        workspaceOpen = open
        editors.forEach { $0.setWorkspaceOpen(open) }
    }

    func activate(_ editor: EditorView, focus: Bool = false) {
        guard editors.contains(where: { $0 === editor }) else { return }
        let changed = activeEditor !== editor
        activeEditor = editor
        if changed { updateGroups() }
        if focus {
            let target: NSView = !editor.markdown.isHidden ? editor.markdown.text : !editor.right.text.isHiddenOrHasHiddenAncestor ? editor.right.text : editor
            window?.makeFirstResponder(target)
        }
        if changed { onActiveChanged?(editor) }
    }

    func splitActiveEditor(copyDocument: Bool = true) {
        guard workspaceOpen, editors.count == 1 else { return }
        let document = activeEditor.activePath.map { ReadingDocument(path: $0, comparison: activeEditor.activeComparison) }
        let editor = EditorView()
        editors.append(editor)
        configure(editor)
        split.addArrangedSubview(editor)
        onEditorAdded?(editor)
        updateGroups()
        onLayoutChanged?()
        layoutSubtreeIfNeeded()
        split.adjustSubviews()
        split.setPosition((split.bounds.width - split.dividerThickness) / 2, ofDividerAt: 0)
        activate(editor, focus: true)
        if copyDocument, let document { onSplitDocument?(document, editor) }
    }

    var splitRatio: Double {
        let total = split.bounds.width - split.dividerThickness
        return editors.count == 2 && total > 0 ? Double(editors[0].frame.width / total) : 0.5
    }

    func restoreSession(_ groups: [EditorReadingSession], active: Int, ratio: Double) {
        if groups.count > 1, editors.count == 1 { splitActiveEditor(copyDocument: false) }
        for (editor, saved) in zip(editors, groups) { editor.restoreSession(saved) }
        layoutSubtreeIfNeeded()
        if editors.count == 2 {
            let total = max(0, split.bounds.width - split.dividerThickness)
            let ratio = ratio.isFinite ? min(1, max(0, ratio)) : 0.5
            split.setPosition(min(max(220, total * ratio), max(220, total - 220)), ofDividerAt: 0)
        }
        activate(editors[min(max(active, 0), editors.count - 1)], focus: true)
    }

    func close(_ editor: EditorView) {
        guard editors.count == 2, let index = editors.firstIndex(where: { $0 === editor }) else { return }
        let wasActive = activeEditor === editor
        editors.remove(at: index)
        editor.removeFromSuperview()
        editor.reset()
        if wasActive { activate(editors[0], focus: true) }
        updateGroups()
        onEditorRemoved?(editor)
        onLayoutChanged?()
        split.adjustSubviews()
    }

    func reset() {
        editors.forEach { $0.reset() }
        if editors.count == 2 { close(editors[1]) }
        activate(editors[0])
    }

    private func configure(_ editor: EditorView) {
        editor.setWorkspaceOpen(workspaceOpen)
        editor.onSplitEditor = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.activate(editor)
            self.splitActiveEditor()
        }
        editor.onCloseGroup = { [weak self, weak editor] in
            guard let editor else { return }
            self?.close(editor)
        }
    }

    private func updateGroups() {
        for (index, editor) in editors.enumerated() {
            let focused = activeEditor === editor
            editor.configureGroup(split: editors.count == 2, focused: focused)
            editor.setAccessibilityElement(true)
            editor.setAccessibilityRole(.group)
            editor.setAccessibilityLabel("Editor group \(index + 1)")
            editor.setAccessibilityValue(focused ? "Active" : "Inactive")
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 220 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - splitView.dividerThickness - 220 }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { editors.count == 1 }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard editors.count == 2 else { editors.first?.frame = splitView.bounds; return }
        let total = max(0, splitView.bounds.width - splitView.dividerThickness)
        let minimum = min(220, total / 2)
        let oldTotal = oldSize.width - splitView.dividerThickness
        let ratio = oldTotal > 0 ? editors[0].frame.width / oldTotal : 0.5
        let width = min(total - minimum, max(minimum, total * ratio))
        editors[0].frame = NSRect(x: 0, y: 0, width: width, height: splitView.bounds.height)
        editors[1].frame = NSRect(x: width + splitView.dividerThickness, y: 0, width: total - width, height: splitView.bounds.height)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) { split.updateTrackingAreas() }
}
