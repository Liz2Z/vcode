import AppKit

final class EditorView: NSView, NSSplitViewDelegate {
    let left = CodePane()
    let right = CodePane()
    let breadcrumbs = EditorBreadcrumbs()
    let welcome = WelcomeView()
    let markdown = MarkdownPreview()
    private let tabs = EditorTabs()
    private let split = ReadingSplitView()
    private let message = Theme.label("", size: 13, color: Theme.muted)
    private var session = ReaderSession()
    private var snapshot: FileSnapshot?
    private var renderedDiff = false
    private var changeIndex = -1
    private var markdownSourcePaths: Set<String> = []
    var showingMarkdownPreview: Bool { !markdown.isHidden }
    private(set) var showingDiff = false
    var activeComparison: GitComparison? { session.activeDocument?.comparison }
    var activePath: String? { session.activePath }
    var onSelectFile: ((String, GitComparison?) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onCursor: (((line: Int, character: Int)) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.rounded(self)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(right)
        message.alignment = .center
        message.maximumNumberOfLines = 3
        add(tabs, breadcrumbs, split, markdown, message, welcome)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor), tabs.leadingAnchor.constraint(equalTo: leadingAnchor), tabs.trailingAnchor.constraint(equalTo: trailingAnchor), tabs.heightAnchor.constraint(equalToConstant: 40),
            breadcrumbs.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4), breadcrumbs.leadingAnchor.constraint(equalTo: leadingAnchor), breadcrumbs.trailingAnchor.constraint(equalTo: trailingAnchor), breadcrumbs.heightAnchor.constraint(equalToConstant: 28),
            split.topAnchor.constraint(equalTo: breadcrumbs.bottomAnchor, constant: 4), split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
            markdown.topAnchor.constraint(equalTo: split.topAnchor), markdown.leadingAnchor.constraint(equalTo: split.leadingAnchor), markdown.trailingAnchor.constraint(equalTo: split.trailingAnchor), markdown.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: split.centerXAnchor), message.centerYAnchor.constraint(equalTo: split.centerYAnchor), message.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 30), message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            welcome.topAnchor.constraint(equalTo: topAnchor), welcome.leadingAnchor.constraint(equalTo: leadingAnchor), welcome.trailingAnchor.constraint(equalTo: trailingAnchor), welcome.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        tabs.onSelect = { [weak self] document in self?.onSelectFile?(document.path, document.comparison) }
        tabs.onClose = { [weak self] document in self?.close(document) }
        tabs.onCloseGroup = { [weak self] document, scope in
            guard let self else { return }
            self.finishClosing(self.session.close(scope, relativeTo: document))
        }
        tabs.onMove = { [weak self] document, index in
            guard let self, self.session.move(document, to: index) else { return }
            self.tabs.show(self.session, revealActive: false)
        }
        welcome.openButton.target = self; welcome.openButton.action = #selector(openFolder)
        breadcrumbs.sourceButton.target = self; breadcrumbs.sourceButton.action = #selector(showMarkdownSource)
        breadcrumbs.previewButton.target = self; breadcrumbs.previewButton.action = #selector(showMarkdownPreview)
        left.onScroll = { [weak self] point in if self?.showingDiff == true { self?.right.sync(to: point) } }
        right.onScroll = { [weak self] point in if self?.showingDiff == true { self?.left.sync(to: point) } }
        right.text.onCursor = { [weak self] index in guard let self, let position = self.right.position(at: index) else { return }; self.onCursor?(position) }
        reset()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setWorkspaceOpen(_ open: Bool) { welcome.show(hasWorkspace: open) }

    func prepare(path: String, diff: Bool, isGit: Bool, comparison: GitComparison = .workingTree) {
        right.text.cancelNavigationFlash()
        right.text.resetSymbolFeedback()
        session.open(path, comparison: diff && isGit ? comparison : nil)
        showingDiff = diff && isGit
        tabs.show(session)
        breadcrumbs.path.stringValue = path.replacingOccurrences(of: "/", with: "  ›  ")
        breadcrumbs.showMarkdownControls(MarkdownRenderer.supports(path) && !showingDiff, preview: !markdownSourcePaths.contains(path))
        tabs.isHidden = false
        breadcrumbs.isHidden = false
        welcome.isHidden = true
        if snapshot?.path != path || snapshot?.comparison != activeComparison { showMessage("Loading…") }
    }

    func show(_ next: FileSnapshot, diff: Bool, preserveScroll: Bool, position: (Int, Int)? = nil, highlightDestination: Bool = false) {
        guard activePath == next.path, next.comparison == activeComparison || next.comparison == nil else { return }
        let scrollPosition = right.scroll.contentView.bounds.origin
        let unchanged = snapshot == next && renderedDiff == diff
        snapshot = next
        renderedDiff = diff
        showingDiff = diff
        welcome.isHidden = true
        if let note = next.message { showMessage(note); return }
        message.isHidden = true
        split.isHidden = false
        left.isHidden = !diff
        // A hidden arranged pane can leave AppKit's cached divider overlay at
        // the old midpoint. Source mode must actually contain just one pane.
        if diff {
            if left.superview !== split { split.insertArrangedSubview(left, at: 0) }
        } else {
            left.removeFromSuperview()
        }
        split.needsDisplay = true
        if !unchanged {
            if diff {
                left.show(lines: next.rows.map(\.left), path: next.path, title: "Original", detail: next.comparison == .unstaged ? "INDEX" : "HEAD")
                right.show(lines: next.rows.map(\.right), path: next.path, title: "Modified", detail: next.comparison == .staged ? "INDEX" : "WORKING TREE")
                split.adjustSubviews()
                split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
                DiffHighlights.apply(next, left: left, right: right)
            } else {
                let lines = Diff.lines(next.after).enumerated().map { CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged) }
                right.show(lines: lines, path: next.path, title: (next.path as NSString).lastPathComponent, detail: "READ ONLY", showsHeader: false)
                split.adjustSubviews()
            }
            right.sync(to: preserveScroll ? scrollPosition : .zero)
            left.sync(to: preserveScroll ? scrollPosition : .zero)
            if !preserveScroll { changeIndex = -1 }
        }
        breadcrumbs.showCounts(diff ? next : nil)
        let supportsPreview = MarkdownRenderer.supports(next.path) && !diff
        let preview = supportsPreview && !markdownSourcePaths.contains(next.path)
        if supportsPreview && !unchanged { markdown.show(next.after) }
        if !supportsPreview { markdown.clear() }
        markdown.isHidden = !preview
        split.isHidden = preview
        breadcrumbs.showMarkdownControls(supportsPreview, preview: preview)
        if let position { right.reveal(line: position.0, character: position.1, highlightDestination: highlightDestination) }
    }

    func showError(_ error: Error) { snapshot = nil; showMessage(error.localizedDescription) }
    private func showMessage(_ text: String) {
        welcome.isHidden = true
        split.isHidden = true
        markdown.isHidden = true
        markdown.clear()
        message.stringValue = text
        message.isHidden = false
        breadcrumbs.showCounts(nil)
    }

    func reset() {
        session.reset()
        tabs.show(session)
        snapshot = nil
        showingDiff = false
        renderedDiff = false
        markdownSourcePaths.removeAll()
        markdown.clear()
        markdown.isHidden = true
        changeIndex = -1
        left.show(lines: [], path: "", title: "", detail: "")
        right.show(lines: [], path: "", title: "", detail: "")
        left.isHidden = true
        left.removeFromSuperview()
        split.isHidden = true
        tabs.isHidden = true
        breadcrumbs.isHidden = true
        welcome.isHidden = false
        message.isHidden = true
        breadcrumbs.path.stringValue = ""
        breadcrumbs.showCounts(nil)
        breadcrumbs.showMarkdownControls(false, preview: false)
    }

    @discardableResult
    func closeActiveTab() -> Bool {
        guard let document = session.activeDocument else { return false }
        close(document)
        return true
    }
    private func close(_ document: ReadingDocument) {
        finishClosing(session.close(document))
    }
    private func finishClosing(_ wasActive: Bool) {
        tabs.show(session)
        guard wasActive else { return }
        snapshot = nil
        if let next = session.activeDocument { onSelectFile?(next.path, next.comparison) }
        else { reset(); onLastTabClosed?() }
    }

    func navigateChange(forward: Bool) {
        guard showingDiff, let snapshot, snapshot.path == activePath else { return }
        let rows = snapshot.changedRows
        let starts = rows.enumerated().filter { $0.offset == 0 || rows[$0.offset - 1] != $0.element - 1 }.map(\.element)
        guard !starts.isEmpty else { return }
        changeIndex = forward ? (changeIndex + 1) % starts.count : (changeIndex <= 0 ? starts.count - 1 : changeIndex - 1)
        right.reveal(row: starts[changeIndex])
    }

    @objc private func openFolder() { onOpenFolder?() }
    @objc func showMarkdownSource() { setMarkdownPreview(false) }
    @objc func showMarkdownPreview() { setMarkdownPreview(true) }
    private func setMarkdownPreview(_ preview: Bool) {
        guard let path = activePath, let snapshot, snapshot.path == path, MarkdownRenderer.supports(path), !showingDiff, snapshot.message == nil else { return }
        if preview { markdownSourcePaths.remove(path) } else { markdownSourcePaths.insert(path) }
        markdown.isHidden = !preview
        split.isHidden = preview
        breadcrumbs.showMarkdownControls(true, preview: preview)
        if preview { window?.makeFirstResponder(markdown.text) } else { window?.makeFirstResponder(right.text) }
    }
    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { subview == left }
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool { !showingDiff }
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 180 }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { splitView.bounds.width - 180 }
}

private final class ReadingSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 8 }
    override var dividerColor: NSColor { Theme.background }
    override func drawDivider(in rect: NSRect) {
        guard arrangedSubviews.count > 1 else { return }
        super.drawDivider(in: rect)
    }
}
