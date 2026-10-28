import AppKit

final class EditorView: NSView, NSSplitViewDelegate {
    let readingID = UUID()
    let left = CodePane()
    let right = CodePane()
    let breadcrumbs = EditorBreadcrumbs()
    let welcome = WelcomeView()
    let markdown = MarkdownPreview()
    let findBar = EditorFindBar()
    private(set) lazy var find = EditorFind(bar: findBar)
    let backButton = Theme.button("arrow.left", tooltip: "Go Back (⌃−)", target: nil, action: nil)
    let forwardButton = Theme.button("arrow.right", tooltip: "Go Forward (⌃⇧−)", target: nil, action: nil)
    let splitEditorButton = Theme.button("rectangle.split.2x1", tooltip: "Split Editor Right (⌘\\)", target: nil, action: nil)
    let closeGroupButton = Theme.button("xmark", tooltip: "Close editor group", target: nil, action: nil)
    private let tabs = EditorTabs()
    private let split = ReadingSplitView()
    private let message = Theme.label("", size: 13, color: Theme.muted)
    private var session = ReaderSession()
    var draftStore = TextDraftStore()
    var sourceEdits: SourceEditStore? {
        didSet {
            oldValue?.removeObserver(readingID)
            sourceEdits?.observe(readingID) { [weak self] path, sender in self?.sourceChanged(path, sender: sender) }
        }
    }
    private var sourceUndo: [String: UndoManager] = [:]
    private var sourceUndoText: [String: String] = [:]
    var onSourceEdited: (() -> Void)?
    var onSourceSaved: ((String) -> Void)?
    var onEditError: ((String) -> Void)?
    private var drafts: [UUID: TextDraft] = [:]
    private var pendingDraftWrites = Set<UUID>()
    private var draftSaveWork: DispatchWorkItem?
    private var draftCloseSheet: DraftCloseSheet?
    private var workspaceOpen = false
    var activeDocument: ReadingDocument? { session.activeDocument }
    var canFind: Bool { activeDocument != nil && (!split.isHidden || showingMarkdownPreview) }
    var isEditingDraft: Bool { session.activeDocument?.isDraft == true }
    var sourceEditingAllowed = false { didSet { updateEditingAvailability() } }
    private var hasSourceBuffer: Bool {
        guard !isEditingDraft, !showingDiff, activeComparison == nil, let snapshot,
              snapshot.path == activePath, let buffer = sourceEdits?.buffer(snapshot.path), message.isHidden else { return false }
        return snapshot.editable || buffer.needsSave
    }
    var isEditableDocument: Bool { isEditingDraft ? right.text.isEditable : activeComparison == nil && activePath.flatMap { sourceEdits?.buffer($0) } != nil && right.text.isEditable }
    var canChangeSourceEditing: Bool { hasSourceBuffer && !editingSuspended }
    var canSaveDocument: Bool {
        guard !editingSuspended else { return false }
        if isEditingDraft { return right.text.isEditable }
        return hasSourceBuffer && (sourceEditingAllowed || activePath.flatMap { sourceEdits?.buffer($0)?.needsSave } == true)
    }
    var onDraftActivated: (() -> Void)?
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
    var editingSuspended = false {
        didSet { updateEditingAvailability() }
    }
    var showingMarkdownPreview: Bool { !markdown.isHidden }
    private(set) var showingDiff = false
    var activeComparison: GitComparison? { session.activeDocument?.comparison }
    var activePath: String? { session.activePath }
    var currentSource: String? {
        guard let snapshot, snapshot.path == activePath,
              snapshot.comparison == activeComparison || snapshot.comparison == nil else { return nil }
        return activeComparison == nil ? sourceEdits?.buffer(snapshot.path)?.text ?? snapshot.after : snapshot.after
    }
    var onSplitEditor: (() -> Void)?
    var onCloseGroup: (() -> Void)?
    var onSelectFile: ((String, GitComparison?) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onCursor: (((line: Int, character: Int)) -> Void)?
    var onSessionChanged: (() -> Void)?
    var onRestoreLocation: ((ReadingLocation) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Theme.rounded(self)
        left.scroll.hasVerticalScroller = false
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
        add(tabs, breadcrumbs, split, markdown, message, welcome, findBar, navigation, groupActions)
        let findWidth = findBar.widthAnchor.constraint(equalToConstant: 420)
        findWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), navigation.topAnchor.constraint(equalTo: topAnchor, constant: 8), navigation.heightAnchor.constraint(equalToConstant: 32),
            tabs.topAnchor.constraint(equalTo: topAnchor), tabs.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 4), tabs.trailingAnchor.constraint(equalTo: groupActions.leadingAnchor, constant: -4), tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            groupActions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), groupActions.topAnchor.constraint(equalTo: topAnchor, constant: 8), groupActions.heightAnchor.constraint(equalToConstant: 32),
            breadcrumbs.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4), breadcrumbs.leadingAnchor.constraint(equalTo: leadingAnchor), breadcrumbs.trailingAnchor.constraint(equalTo: trailingAnchor), breadcrumbs.heightAnchor.constraint(equalToConstant: 28),
            findBar.topAnchor.constraint(equalTo: right.scroll.topAnchor, constant: 8), findBar.trailingAnchor.constraint(equalTo: right.scroll.trailingAnchor, constant: -8), findBar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8), findWidth,
            split.topAnchor.constraint(equalTo: breadcrumbs.bottomAnchor, constant: 4), split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
            markdown.topAnchor.constraint(equalTo: split.topAnchor), markdown.leadingAnchor.constraint(equalTo: split.leadingAnchor), markdown.trailingAnchor.constraint(equalTo: split.trailingAnchor), markdown.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            message.centerXAnchor.constraint(equalTo: split.centerXAnchor), message.centerYAnchor.constraint(equalTo: split.centerYAnchor), message.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 30), message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -30),
            welcome.topAnchor.constraint(equalTo: tabs.bottomAnchor), welcome.leadingAnchor.constraint(equalTo: leadingAnchor), welcome.trailingAnchor.constraint(equalTo: trailingAnchor), welcome.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        tabs.onSelect = { [weak self] document in self?.selectDocument(document) }
        tabs.onNewText = { [weak self] in self?.newTextTab() }
        tabs.titleForDocument = { [weak self] document in self?.documentTitle(document) ?? document.path }
        splitEditorButton.target = self; splitEditorButton.action = #selector(splitEditor)
        closeGroupButton.target = self; closeGroupButton.action = #selector(closeGroup)
        backButton.target = self; backButton.action = #selector(goBack)
        forwardButton.target = self; forwardButton.action = #selector(goForward)
        configureGroup(split: false, focused: true)
        splitEditorButton.isEnabled = false
        tabs.onClose = { [weak self] document in self?.close(document) }
        tabs.onCloseGroup = { [weak self] document, scope in
            guard let self else { return }
            self.requestClose(self.session.documentsToClose(scope, relativeTo: document))
        }
        tabs.onMove = { [weak self] document, index in
            guard let self, self.session.move(document, to: index) else { return }
            self.tabs.show(self.session, revealActive: false)
            self.onSessionChanged?()
        }
        welcome.openButton.target = self; welcome.openButton.action = #selector(openFolder)
        breadcrumbs.sourceButton.target = self; breadcrumbs.sourceButton.action = #selector(showMarkdownSource)
        breadcrumbs.previewButton.target = self; breadcrumbs.previewButton.action = #selector(showMarkdownPreview)
        left.onScroll = { [weak self] point in if self?.showingDiff == true { self?.right.sync(to: point) } }
        right.onScroll = { [weak self] point in if self?.showingDiff == true { self?.left.sync(to: point) } }
        right.text.onTextChange = { [weak self] in
            guard let self else { return }
            self.editableChanged()
            self.find.didChangeText(in: self.right)
        }
        for pane in [left, right] {
            pane.text.isPointerObscured = { [weak self] point in
                guard let self, !self.findBar.isHiddenOrHasHiddenAncestor else { return false }
                return self.findBar.bounds.contains(self.findBar.convert(point, from: nil))
            }
            pane.text.onFindAction = { [weak self, weak pane] action in
                guard let self, let pane else { return }
                self.find.perform(action, in: pane)
            }
            pane.text.onWillChangeText = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.find.willChangeText(in: pane)
            }
            pane.onWillReplaceText = { [weak self, weak pane] in
                guard let self, let pane else { return }
                self.find.willChangeText(in: pane, replacing: true)
            }
        }
        left.onSearchMatchesChanged = { [weak self] in
            guard let self else { return }
            self.right.additionalSearchRows = self.showingDiff ? self.left.overviewRows(for: self.left.text.searchRanges) : []
            self.right.additionalCurrentSearchRows = self.showingDiff ? self.left.overviewRows(for: self.left.text.currentSearchRange.map { [$0] } ?? []) : []
        }
        right.text.onCursor = { [weak self] index in guard let self, let position = self.right.position(at: index) else { return }; self.onCursor?(position) }
        markdown.onRendered = { [weak self] in
            guard let self else { return }
            self.completeArrival(fallback: self.pendingRestore)
        }
        reset()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { sourceEdits?.removeObserver(readingID) }
    override var acceptsFirstResponder: Bool { true }

    private func updateEditingAvailability() {
        let editable = !editingSuspended && message.isHidden && (isEditingDraft || (sourceEditingAllowed && hasSourceBuffer))
        if right.text.isEditable != editable { right.text.breakUndoCoalescing(); right.text.isEditable = editable }
    }

    func performFind(_ action: NSTextFinder.Action) {
        guard canFind else { return }
        if showingMarkdownPreview { showMarkdownSource() }
        let responder = window?.firstResponder as? NSView
        let pane: CodePane
        if responder.map({ $0.isDescendant(of: findBar) || $0 === findBar.query.currentEditor() }) == true, let searching = find.currentPane { pane = searching }
        else { pane = showingDiff && responder.map { $0 === left.text || $0.isDescendant(of: left) } == true ? left : right }
        find.perform(action, in: pane)
    }

    func setWorkspaceOpen(_ open: Bool) { workspaceOpen = open; welcome.show(hasWorkspace: open); splitEditorButton.isEnabled = open }

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
        onSessionChanged?()
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
        let buffer: SourceEditStore.Buffer?
        do {
            buffer = !diff && (next.editable || sourceEdits?.buffer(next.path)?.needsSave == true) ? try sourceEdits?.open(next.path) : nil
        } catch { showMessage("Could not open for editing: " + error.localizedDescription); right.text.isEditable = false; return }
        if let note = next.message, buffer == nil { showMessage(note); completeArrival(fallback: restoration); return }
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
        if !unchanged || (buffer != nil && right.text.string != buffer?.text) {
            right.text.documentUndoManager = nil
            right.additionalSearchRows = []
            right.additionalCurrentSearchRows = []
            right.showDiffOverview(diff ? next.rows : nil, source: !diff)
            if diff {
                left.show(lines: next.rows.map(\.left), path: next.path, title: "Original", detail: next.comparison == .unstaged ? "INDEX" : "HEAD")
                right.show(lines: next.rows.map(\.right), path: next.path, title: "Modified", detail: next.comparison == .staged ? "INDEX" : "WORKING TREE")
                split.adjustSubviews()
                split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
                DiffHighlights.apply(next, left: left, right: right)
            } else {
                if let buffer {
                    right.showEditable(buffer.text, path: next.path)
                    let undo = sourceUndo[next.path] ?? UndoManager()
                    sourceUndo[next.path] = undo
                    sourceUndoText[next.path] = buffer.text
                    right.text.documentUndoManager = undo
                    right.text.supportsCodeIntelligence = true
                } else {
                    let lines = Diff.lines(next.after).enumerated().map { CodeLine(number: $0.offset + 1, text: $0.element, kind: .unchanged) }
                    right.show(lines: lines, path: next.path, title: (next.path as NSString).lastPathComponent, detail: "READ ONLY", showsHeader: false)
                }
                split.adjustSubviews()
            }
            right.resetScroll()
            if diff { left.resetScroll() }
            if !preserveScroll { changeIndex = -1 }
        }
        breadcrumbs.showCounts(diff ? next : nil)
        let supportsPreview = MarkdownRenderer.supports(next.path) && !diff
        let preview = supportsPreview && !markdownSourcePaths.contains(next.path)
        if supportsPreview && !unchanged { markdown.show(buffer?.text ?? next.after, restoring: restoration?.markdown) }
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
        updateEditingAvailability()
        if buffer != nil { showSourceLabel() }
    }

    func showError(_ error: Error) { snapshot = nil; showMessage(error.localizedDescription) }
    private func showMessage(_ text: String) {
        find.close(restoreFocus: false)
        welcome.isHidden = true
        split.isHidden = true
        markdown.isHidden = true
        markdown.clear()
        message.stringValue = text
        message.isHidden = false
        updateEditingAvailability()
        breadcrumbs.showCounts(nil)
    }

    func reset(clearHistory: Bool = true) {
        flushDrafts()
        right.text.documentUndoManager = nil
        sourceUndo = [:]
        sourceUndoText = [:]
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
        right.showDiffOverview(nil)
        left.isHidden = true
        left.removeFromSuperview()
        split.isHidden = true
        tabs.isHidden = false
        breadcrumbs.isHidden = true
        welcome.isHidden = false
        message.isHidden = true
        breadcrumbs.path.stringValue = ""
        breadcrumbs.showCounts(nil)
        breadcrumbs.showMarkdownControls(false, preview: false)
    }

    func documentTitle(_ document: ReadingDocument) -> String {
        guard let id = document.draftID else { return (document.path as NSString).lastPathComponent + (document.comparison == nil && sourceEdits?.buffer(document.path)?.needsSave == true ? " •" : "") }
        let draft = drafts[id] ?? (try? draftStore.load(id))
        return (draft?.destination?.lastPathComponent ?? document.path) + (draft?.needsSave == true ? " •" : "")
    }

    @objc func newTextTab() {
        guard workspaceOpen else { NSSound.beep(); return }
        let number = (1...).first { number in !session.documents.contains { $0.path == "Untitled-\(number)" } }!
        let document = ReadingDocument(path: "Untitled-\(number)", comparison: nil, draftID: UUID())
        do {
            try draftStore.save(TextDraft(), id: document.draftID!)
            openDraft(document)
        } catch { breadcrumbs.path.stringValue = "Could not create draft: " + error.localizedDescription }
    }

    private func selectDocument(_ document: ReadingDocument) {
        if document.isDraft { openDraft(document) }
        else { onSelectFile?(document.path, document.comparison) }
    }

    func openDraft(_ document: ReadingDocument, restoring: ReadingLocation? = nil, recordNavigation: Bool = true) {
        guard let id = document.draftID else { return }
        if recordNavigation { saveReadingPosition() }
        session.open(document)
        snapshot = nil
        showingDiff = false
        pendingArrival = true; recordArrival = recordNavigation
        pendingRestore = restoring ?? savedPositions[document]
        tabs.show(session)
        welcome.isHidden = true; tabs.isHidden = false; breadcrumbs.isHidden = false
        breadcrumbs.showCounts(nil); breadcrumbs.showMarkdownControls(false, preview: false)
        markdown.clear(); markdown.isHidden = true
        left.removeFromSuperview(); left.isHidden = true
        right.showDiffOverview(nil)
        do {
            let draft = try drafts[id] ?? draftStore.load(id)
            drafts[id] = draft
            right.text.documentUndoManager = nil
            right.showEditable(draft.text, path: draft.destination?.path ?? "")
            split.isHidden = false; message.isHidden = true
            updateEditingAvailability()
            split.adjustSubviews(); right.resetScroll()
            if let location = pendingRestore { right.restore(location.right) }
            showDraftLabel()
            completeArrival(fallback: pendingRestore)
            onDraftActivated?()
            window?.makeFirstResponder(right.text)
        } catch {
            // Do not replace an unreadable draft with an empty, writable document.
            right.text.isEditable = false
            showMessage("Could not read draft: " + error.localizedDescription)
        }
        onSessionChanged?()
    }

    private func editableChanged() {
        if !isEditingDraft, let path = activePath, activeComparison == nil, sourceEdits?.buffer(path) != nil {
            right.updateEditableLines(path: path)
            sourceEdits?.update(path, text: right.text.string, sender: readingID)
            return
        }
        guard let document = session.activeDocument, let id = document.draftID, var draft = drafts[id] else { return }
        let wasDirty = draft.needsSave
        draft.text = right.text.string
        drafts[id] = draft
        pendingDraftWrites.insert(id)
        right.updateEditableLines(path: draft.destination?.path ?? "")
        if wasDirty != draft.needsSave { tabs.show(session, revealActive: false) }
        showDraftLabel()
        draftSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushDrafts(); self?.onSessionChanged?() }
        draftSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func showDraftLabel() {
        guard let document = session.activeDocument, let id = document.draftID, let draft = drafts[id] else { return }
        breadcrumbs.path.stringValue = (draft.destination?.path ?? document.path) + (draft.needsSave ? "  ·  Edited" : "  ·  Editable")
    }

    private func showSourceLabel() {
        guard let path = activePath, activeComparison == nil, let buffer = sourceEdits?.buffer(path) else { return }
        breadcrumbs.path.stringValue = path.replacingOccurrences(of: "/", with: "  ›  ") + (buffer.needsSave ? "  ·  Edited" : "")
    }

    private func sourceChanged(_ path: String, sender: UUID?) {
        tabs.show(session, revealActive: false)
        if let buffer = sourceEdits?.buffer(path) {
            if sender != readingID, let previous = sourceUndoText[path], previous != buffer.text { sourceUndo[path]?.removeAllActions() }
            sourceUndoText[path] = buffer.text
        } else { sourceUndo[path]?.removeAllActions(); sourceUndoText.removeValue(forKey: path) }
        guard activePath == path, activeComparison == nil else { return }
        guard let buffer = sourceEdits?.buffer(path) else { onSourceSaved?(path); return }
        if sender != readingID, right.text.string != buffer.text {
            // Another group changed the shared working copy. Keep this group's
            // viewport, but invalidate undo operations against the older text.
            let position = right.readingPosition()
            find.willChangeText(in: right)
            right.text.cancelInspection(); right.text.resetSymbolFeedback()
            sourceUndo[path]?.removeAllActions()
            right.text.breakUndoCoalescing()
            right.text.string = buffer.text
            right.updateEditableLines(path: path, allowReadOnly: true)
            right.restore(position)
            find.didChangeText(in: right)
        }
        if showingMarkdownPreview { markdown.show(buffer.text, restoring: markdown.readingPosition()) }
        showSourceLabel()
        onSourceEdited?()
        onSessionChanged?()
    }

    private func flushDrafts() {
        draftSaveWork?.cancel(); draftSaveWork = nil
        for id in Array(pendingDraftWrites) {
            guard let draft = drafts[id] else { continue }
            do { try draftStore.save(draft, id: id); pendingDraftWrites.remove(id) }
            catch { breadcrumbs.path.stringValue = "Could not preserve draft: " + error.localizedDescription }
        }
    }

    func saveTextAs(alwaysChoose: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if !isEditingDraft { saveSourceAs(alwaysChoose: alwaysChoose, completion: completion); return }
        guard let document = session.activeDocument, let id = document.draftID, let draft = drafts[id], let window else { completion?(false); return }
        func save(to url: URL) {
            do {
                let saved = try draftStore.export(draft, to: url)
                drafts[id] = saved
                try draftStore.save(saved, id: id)
                showDraftLabel(); tabs.show(session, revealActive: false)
                right.updateEditableLines(path: url.path)
                onSessionChanged?()
                completion?(true)
            } catch {
                breadcrumbs.path.stringValue = "Could not save: " + error.localizedDescription
                completion?(false)
            }
        }
        if !alwaysChoose, let destination = draft.destination { save(to: destination); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = draft.destination?.lastPathComponent ?? document.path + ".txt"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url { save(to: url) }
            else { completion?(false) }
        }
    }

    private func saveSourceAs(alwaysChoose: Bool, completion: ((Bool) -> Void)?) {
        guard canSaveDocument, let path = activePath, let sourceEdits else { completion?(false); return }
        if !alwaysChoose {
            do { try sourceEdits.save(path); onSourceSaved?(path); completion?(true) }
            catch { reportEditError(error); completion?(false) }
            return
        }
        guard let window else { completion?(false); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.directoryURL = sourceEdits.root?.appendingPathComponent(path).deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] result in
            guard let self, result == .OK, let url = panel.url else { completion?(false); return }
            do { try sourceEdits.export(path, to: url); self.onSourceSaved?(path); completion?(true) }
            catch { self.reportEditError(error); completion?(false) }
        }
    }

    private func reportEditError(_ error: Error) {
        breadcrumbs.path.stringValue = "Could not save: " + error.localizedDescription
        onEditError?(error.localizedDescription)
    }

    func requestClose(_ documents: [ReadingDocument], completion: (() -> Void)? = nil) {
        guard draftCloseSheet == nil else { return }
        saveReadingPosition()
        var discardedSources: [String] = []
        func confirm(_ index: Int) {
            guard index < documents.count else {
                do { for path in discardedSources { try sourceEdits?.discard(path) } }
                catch { reportEditError(error); return }
                finishClosing(session.close(documents))
                completion?()
                return
            }
            let document = documents[index]
            if !document.isDraft, document.comparison == nil, sourceEdits?.buffer(document.path)?.needsSave == true {
                guard let window else { return }
                let sheet = DraftCloseSheet(title: document.path) { [weak self] choice in
                    guard let self else { return }
                    self.draftCloseSheet = nil
                    switch choice {
                    case .cancel: break
                    case .discard: discardedSources.append(document.path); confirm(index + 1)
                    case .save:
                        do { try self.sourceEdits?.save(document.path); self.onSourceSaved?(document.path); confirm(index + 1) }
                        catch { self.reportEditError(error) }
                    }
                }
                draftCloseSheet = sheet
                window.beginSheet(sheet)
                return
            }
            guard let id = document.draftID, (drafts[id] ?? (try? draftStore.load(id)))?.needsSave == true, let window else { confirm(index + 1); return }
            // Switch to the exact draft the close operation is asking about.
            openDraft(document)
            let sheet = DraftCloseSheet(title: documentTitle(document)) { [weak self] choice in
                guard let self else { return }
                self.draftCloseSheet = nil
                switch choice {
                case .cancel: break
                case .discard: confirm(index + 1)
                case .save: self.saveTextAs { saved in if saved { confirm(index + 1) } }
                }
            }
            draftCloseSheet = sheet
            window.beginSheet(sheet)
        }
        confirm(0)
    }

    func requestCloseGroup(completion: @escaping () -> Void) {
        requestClose(session.documents, completion: completion)
    }

    @discardableResult
    func closeActiveTab() -> Bool {
        guard let document = session.activeDocument else { return false }
        close(document)
        return true
    }
    private func close(_ document: ReadingDocument) { requestClose([document]) }
    private func finishClosing(_ wasActive: Bool) {
        onSessionChanged?()
        tabs.show(session)
        guard wasActive else { return }
        snapshot = nil
        if let next = session.activeDocument { selectDocument(next) }
        else { reset(clearHistory: false); onLastTabClosed?() }
    }

    func readingLocation() -> ReadingLocation? {
        guard let document = session.activeDocument else { return nil }
        if document.isDraft {
            guard right.text.isEditable else { return savedPositions[document] }
            return ReadingLocation(document: document, right: right.readingPosition(), left: left.readingPosition(), markdown: nil, preview: false)
        }
        guard let snapshot, snapshot.path == document.path,
              snapshot.comparison == document.comparison else { return nil }
        if snapshot.message != nil && !hasSourceBuffer { return savedPositions[document] }
        return ReadingLocation(document: document, right: right.readingPosition(), left: left.readingPosition(),
            markdown: markdown.readingPosition(), preview: showingMarkdownPreview)
    }

    private func saveReadingPosition() {
        right.text.breakUndoCoalescing()
        flushDrafts()
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
        onSessionChanged?()
    }

    func captureSession() -> EditorReadingSession {
        flushDrafts()
        do { try sourceEdits?.flush() } catch { reportEditError(error) }
        var positions = savedPositions
        // An app exit can arrive before the active document's asynchronous render.
        // Keep its saved anchor instead of capturing the temporary loading view.
        if let location = (pendingArrival ? pendingRestore : nil) ?? readingLocation() { positions[location.document] = location }
        return EditorReadingSession(documents: session.documents, activeDocument: session.activeDocument,
            positions: session.documents.compactMap { positions[$0] }, markdownSourcePaths: markdownSourcePaths.sorted())
    }

    func restoreSession(_ saved: EditorReadingSession) {
        reset()
        let saved = saved.validated
        session.restore(documents: saved.documents, active: saved.activeDocument)
        for document in saved.documents where !document.isDraft && document.comparison == nil {
            do { try sourceEdits?.restoreRecovery(document.path) }
            catch { onEditError?("Could not restore \(document.path): " + error.localizedDescription) }
        }
        for location in saved.positions { savedPositions[location.document] = location }
        markdownSourcePaths = Set(saved.markdownSourcePaths)
        tabs.show(session)
        if let document = session.activeDocument, document.isDraft { openDraft(document, recordNavigation: false) }
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
        if location.document.isDraft { openDraft(location.document, restoring: location, recordNavigation: false) }
        else { onRestoreLocation?(location) }
    }

    func renamePaths(_ renames: [String: String]) {
        guard !renames.isEmpty else { return }
        saveReadingPosition()
        session.renamePaths(renames)
        readingHistory.renamePaths(renames)
        var positions: [ReadingDocument: ReadingLocation] = [:]
        for var location in savedPositions.values {
            location.document = location.document.isDraft ? location.document : ReadingDocument(path: renames[location.document.path] ?? location.document.path, comparison: location.document.comparison)
            positions[location.document] = location
        }
        savedPositions = positions
        markdownSourcePaths = Set(markdownSourcePaths.map { renames[$0] ?? $0 })
        if let old = snapshot, let path = renames[old.path] {
            snapshot = FileSnapshot(path: path, before: old.before, after: old.after, rows: old.rows, message: old.message, isBinary: old.isBinary, comparison: old.comparison, editable: old.editable)
            needsRender = true
        }
        if var location = pendingRestore {
            location.document = location.document.isDraft ? location.document : ReadingDocument(path: renames[location.document.path] ?? location.document.path, comparison: location.document.comparison)
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
        if preview { find.close(restoreFocus: false); markdownSourcePaths.remove(path) } else { markdownSourcePaths.insert(path) }
        markdown.isHidden = !preview
        split.isHidden = preview
        breadcrumbs.showMarkdownControls(true, preview: preview)
        if preview { markdown.show(sourceEdits?.buffer(path)?.text ?? snapshot.after, restoring: markdown.readingPosition()) }
        onSessionChanged?()
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
