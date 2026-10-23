import AppKit

final class EditorView: NSView, NSSplitViewDelegate {
    let readingID = UUID()
    let left = CodePane()
    let right = CodePane()
    let breadcrumbs = EditorBreadcrumbs()
    let welcome = WelcomeView()
    let markdown = MarkdownPreview()
    let backButton = Theme.button("arrow.left", tooltip: "Go Back (⌃−)", target: nil, action: nil)
    let forwardButton = Theme.button("arrow.right", tooltip: "Go Forward (⌃⇧−)", target: nil, action: nil)
    let splitEditorButton = Theme.button("rectangle.split.2x1", tooltip: "Split Editor Right (⌘\\)", target: nil, action: nil)
    let closeGroupButton = Theme.button("xmark", tooltip: "Close editor group", target: nil, action: nil)
    private let tabs = EditorTabs()
    private let split = ReadingSplitView()
    private let message = Theme.label("", size: 13, color: Theme.muted)
    private var session = ReaderSession()
    private var snapshot: FileSnapshot?
    private var renderedDiff = false
    private var needsRender = false
    private var changeIndex = -1
    private var markdownSourcePaths: Set<String> = []
    private var readingHistory = ReadingHistory()
    private var savedPositions: [ReadingDocument: ReadingLocation] = [:]
    private var pendingRestore: ReadingLocation?
    private var pendingArrival = false
    private var recordArrival = true
    var canGoBack: Bool { readingHistory.canGoBack }
    var canGoForward: Bool { readingHistory.canGoForward }
    var allowsNavigation = true { didSet { updateNavigationButtons() } }
    var showingMarkdownPreview: Bool { !markdown.isHidden }
    private(set) var showingDiff = false
    var activeComparison: GitComparison? { session.activeDocument?.comparison }
    var activePath: String? { session.activePath }
    var currentSource: String? {
        guard let snapshot, snapshot.path == activePath,
              snapshot.comparison == activeComparison || snapshot.comparison == nil else { return nil }
        return snapshot.after
    }
    var onSplitEditor: (() -> Void)?
    var onCloseGroup: (() -> Void)?
    var onSelectFile: ((String, GitComparison?) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onCursor: (((line: Int, character: Int)) -> Void)?
    var onRestoreLocation: ((ReadingLocation) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.rounded(self)
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(right)
        message.alignment = .center
        message.maximumNumberOfLines = 3
        let groupActions = NSStackView(views: [splitEditorButton, closeGroupButton])
        groupActions.orientation = .horizontal
        groupActions.spacing = 4
        groupActions.alignment = .centerY
        let navigation = NSStackView(views: [backButton, forwardButton])
        navigation.orientation = .horizontal
        navigation.spacing = 0
        for button in [splitEditorButton, closeGroupButton, backButton, forwardButton] {
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        add(tabs, breadcrumbs, split, markdown, message, welcome, navigation, groupActions)
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), navigation.topAnchor.constraint(equalTo: topAnchor, constant: 8), navigation.heightAnchor.constraint(equalToConstant: 32),
            tabs.topAnchor.constraint(equalTo: topAnchor), tabs.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 4), tabs.trailingAnchor.constraint(equalTo: groupActions.leadingAnchor, constant: -4), tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            groupActions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), groupActions.topAnchor.constraint(equalTo: topAnchor, constant: 8), groupActions.heightAnchor.constraint(equalToConstant: 32),
            breadcrumbs.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4), breadcrumbs.leadingAnchor.constraint(equalTo: leadingAnchor), breadcrumbs.trailingAnchor.constraint(equalTo: trailingAnchor), breadcrumbs.heightAnchor.constraint(equalToConstant: 28),
            split.topAnchor.constraint(equalTo: breadcrumbs.bottomAnchor, constant: 4), split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
            markdown.topAnchor.constraint(equalTo: split.topAnchor), markdown.leadingAnchor.constraint(equalTo: split.leadingAnchor), markdown.trailingAnchor.constraint(equalTo: split.trailingAnchor), markdown.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: split.centerXAnchor), message.centerYAnchor.constraint(equalTo: split.centerYAnchor), message.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 30), message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            welcome.topAnchor.constraint(equalTo: topAnchor), welcome.leadingAnchor.constraint(equalTo: leadingAnchor), welcome.trailingAnchor.constraint(equalTo: trailingAnchor), welcome.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        tabs.onSelect = { [weak self] document in self?.onSelectFile?(document.path, document.comparison) }
        splitEditorButton.target = self; splitEditorButton.action = #selector(splitEditor)
        closeGroupButton.target = self; closeGroupButton.action = #selector(closeGroup)
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        configureGroup(split: false, focused: true)
        splitEditorButton.isEnabled = false
        tabs.onClose = { [weak self] document in self?.close(document) }
        tabs.onCloseGroup = { [weak self] document, scope in
            guard let self else { return }
            self.saveReadingPosition()
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
        markdown.onRendered = { [weak self] in
            guard let self else { return }
            self.completeArrival(fallback: self.pendingRestore)
        }
        reset()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    func setWorkspaceOpen(_ open: Bool) { welcome.show(hasWorkspace: open); splitEditorButton.isEnabled = open }

    func configureGroup(split: Bool, focused: Bool) {
        splitEditorButton.isHidden = split
        closeGroupButton.isHidden = !split
        tabs.setGroupFocused(focused)
    }

    @objc private func splitEditor() { onSplitEditor?() }
    @objc private func closeGroup() { onCloseGroup?() }

    func prepare(path: String, diff: Bool, isGit: Bool, comparison: GitComparison = .workingTree, restoring location: ReadingLocation? = nil, recordNavigation: Bool = true, forceSource: Bool = false) {
        if recordNavigation { saveReadingPosition() }
        right.text.cancelNavigationFlash()
        right.text.resetSymbolFeedback()
        session.open(path, comparison: diff && isGit ? comparison : nil)
        pendingRestore = location ?? session.activeDocument.flatMap { savedPositions[$0] }
        pendingArrival = true
        recordArrival = recordNavigation
        if let pendingRestore, MarkdownRenderer.supports(path) {
            if pendingRestore.preview { markdownSourcePaths.remove(path) } else { markdownSourcePaths.insert(path) }
        }
        if forceSource { markdownSourcePaths.insert(path) }
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
        let restoration = pendingArrival ? pendingRestore : preserveScroll ? readingLocation() : nil
        if let restoration { savedPositions[restoration.document] = restoration }
        let unchanged = snapshot == next && renderedDiff == diff && !needsRender
        needsRender = false
        snapshot = next
        renderedDiff = diff
        showingDiff = diff
        welcome.isHidden = true
        if let note = next.message { showMessage(note); completeArrival(fallback: restoration); return }
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
            right.resetScroll()
            if diff { left.resetScroll() }
            if !preserveScroll { changeIndex = -1 }
        }
        breadcrumbs.showCounts(diff ? next : nil)
        let supportsPreview = MarkdownRenderer.supports(next.path) && !diff
        let preview = supportsPreview && !markdownSourcePaths.contains(next.path)
        if supportsPreview && !unchanged { markdown.show(next.after, restoring: restoration?.markdown) }
        if !supportsPreview { markdown.clear() }
        markdown.isHidden = !preview
        split.isHidden = preview
        breadcrumbs.showMarkdownControls(supportsPreview, preview: preview)
        if let restoration, !unchanged || pendingArrival {
            right.restore(restoration.right)
            if diff { left.restore(restoration.left) }
            if supportsPreview && unchanged, !markdown.isRendering { markdown.restore(restoration.markdown) }
        }
        if let position { right.reveal(line: position.0, character: position.1, highlightDestination: highlightDestination) }
        if !markdown.isRendering { completeArrival(fallback: restoration) }
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

    func reset(clearHistory: Bool = true) {
        session.reset()
        tabs.show(session)
        snapshot = nil
        showingDiff = false
        renderedDiff = false
        needsRender = false
        markdownSourcePaths.removeAll()
        pendingRestore = nil; pendingArrival = false
        if clearHistory { readingHistory = ReadingHistory(); savedPositions = [:] }
        updateNavigationButtons()
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
        saveReadingPosition()
        finishClosing(session.close(document))
    }
    private func finishClosing(_ wasActive: Bool) {
        tabs.show(session)
        guard wasActive else { return }
        snapshot = nil
        if let next = session.activeDocument { onSelectFile?(next.path, next.comparison) }
        else { reset(clearHistory: false); onLastTabClosed?() }
    }

    func readingLocation() -> ReadingLocation? {
        guard let document = session.activeDocument else { return nil }
        guard let snapshot, snapshot.path == document.path,
              snapshot.comparison == document.comparison else { return nil }
        if snapshot.message != nil { return savedPositions[document] }
        return ReadingLocation(document: document, right: right.readingPosition(), left: left.readingPosition(),
            markdown: markdown.readingPosition(), preview: showingMarkdownPreview)
    }

    private func saveReadingPosition() {
        guard let location = readingLocation() else { return }
        savedPositions[location.document] = location
        if pendingArrival && recordArrival { readingHistory.visit(location) }
        else { readingHistory.updateCurrent(location) }
        pendingArrival = false; pendingRestore = nil
        updateNavigationButtons()
    }

    private func completeArrival(fallback: ReadingLocation?) {
        if let location = readingLocation() ?? fallback {
            savedPositions[location.document] = location
            if pendingArrival && recordArrival { readingHistory.visit(location) }
            else if !pendingArrival { readingHistory.updateCurrent(location) }
        }
        pendingArrival = false; pendingRestore = nil
        updateNavigationButtons()
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = allowsNavigation && canGoBack
        forwardButton.isEnabled = allowsNavigation && canGoForward
    }

    @objc func goBack() { moveHistory(forward: false) }
    @objc func goForward() { moveHistory(forward: true) }
    private func moveHistory(forward: Bool) {
        guard allowsNavigation else { return }
        let current = readingLocation()
        if let current { savedPositions[current.document] = current }
        guard let location = readingHistory.move(forward: forward, current: current) else { return }
        updateNavigationButtons()
        onRestoreLocation?(location)
    }

    func renamePaths(_ renames: [String: String]) {
        guard !renames.isEmpty else { return }
        saveReadingPosition()
        session.renamePaths(renames)
        readingHistory.renamePaths(renames)
        var positions: [ReadingDocument: ReadingLocation] = [:]
        for var location in savedPositions.values {
            location.document = ReadingDocument(path: renames[location.document.path] ?? location.document.path, comparison: location.document.comparison)
            positions[location.document] = location
        }
        savedPositions = positions
        markdownSourcePaths = Set(markdownSourcePaths.map { renames[$0] ?? $0 })
        if let old = snapshot, let path = renames[old.path] {
            snapshot = FileSnapshot(path: path, before: old.before, after: old.after, rows: old.rows, message: old.message, isBinary: old.isBinary, comparison: old.comparison)
            needsRender = true
        }
        if var location = pendingRestore {
            location.document = ReadingDocument(path: renames[location.document.path] ?? location.document.path, comparison: location.document.comparison)
            pendingRestore = location
        }
        tabs.show(session)
        if let path = activePath { breadcrumbs.path.stringValue = path.replacingOccurrences(of: "/", with: "  ›  ") }
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
