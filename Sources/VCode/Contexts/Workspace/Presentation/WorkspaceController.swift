import AppKit

final class WorkspaceController: NSViewController, NSUserInterfaceValidations {
    private let workspace = WorkspaceView()
    private let session = WorkspaceSession()
    private let language = LanguageService()
    private let inspection: InspectionPresenter
    private var changesOnly = false
    private var inspectToken = UUID()
    private var hoverRequest = UUID()
    private weak var inspectionEditor: EditorView?
    private var languageStatus = ""
    private var observer: NSObjectProtocol?
    private var picker: NSPopover?
    private var pickerRequest = UUID()
    private var displayedState: WorkspaceState?
    private var readingSave: DispatchWorkItem?
    private var readingObservers: [NSObjectProtocol] = []
    private var readingStateReady = false
    private var treeSessions: [String: FileTreeReadingState] = [:]
    private var externalURLs: [URL] = []
    private var externalOpenBusy = false
    private var externalOpenToken = UUID()
    private var externalOpenFailures: [ExternalOpenNotice.Failure] = []
    private let history: WorkspaceHistoryStore
    private(set) var historySidebar: WorkspaceHistorySidebar!
    private var historyWidthSave: DispatchWorkItem?
    let projectSearch = ProjectSearchController()
    private(set) var quickOpen: QuickOpenPicker?
    private var quickOpenMonitor: Any?
    private(set) var shortcutsPicker: KeyboardShortcutsController?
    private var shortcutsMonitor: Any?
    private var shortcutKeyMonitor: Any?
    private var shortcutFocusObserver: NSObjectProtocol?
    private var shortcutChord = KeyboardShortcutChord()
    private var shortcutChordReset: DispatchWorkItem?
    private var shortcutMessageBeforeChord: String?
    private weak var shortcutPreviousFocus: NSView?
    private let shortcutChordHint = "⌘K pressed · ⌘S: Keyboard Shortcuts · Esc: Cancel"

    init(history: WorkspaceHistoryStore = WorkspaceHistoryStore(), inspection: InspectionPresenter = InspectionPresenter()) {
        self.history = history
        self.inspection = inspection
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = workspace
        addChild(projectSearch)
        workspace.searchHost.add(projectSearch.view)
        NSLayoutConstraint.activate([
            projectSearch.view.leadingAnchor.constraint(equalTo: workspace.searchHost.leadingAnchor), projectSearch.view.trailingAnchor.constraint(equalTo: workspace.searchHost.trailingAnchor),
            projectSearch.view.topAnchor.constraint(equalTo: workspace.searchHost.topAnchor), projectSearch.view.bottomAnchor.constraint(equalTo: workspace.searchHost.bottomAnchor)
        ])
        configureHistorySidebar()
        configureActions()
        configureShortcutKeys()
        configureReadingPersistence()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit {
        readingSave?.cancel()
        readingObservers.forEach(NotificationCenter.default.removeObserver)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        historyWidthSave?.cancel()
        if let quickOpenMonitor { NSEvent.removeMonitor(quickOpenMonitor) }
        if let shortcutsMonitor { NSEvent.removeMonitor(shortcutsMonitor) }
        if let shortcutKeyMonitor { NSEvent.removeMonitor(shortcutKeyMonitor) }
        if let shortcutFocusObserver { NotificationCenter.default.removeObserver(shortcutFocusObserver) }
        shortcutChordReset?.cancel()
        language.stop()
    }

    private func configureActions() {
        workspace.openNotice.onDismiss = { [weak self] in
            self?.externalOpenFailures = []
            self?.workspace.dismissOpenNotice()
        }
        history.onError = { [weak self] message in
            self?.workspace.status.message.stringValue = message
            self?.workspace.status.message.toolTip = message
        }
        workspace.header.openButton.target = self; workspace.header.openButton.action = #selector(openFolder)
        workspace.header.branchButton.target = self; workspace.header.branchButton.action = #selector(showBranches)
        workspace.header.worktreeButton.target = self; workspace.header.worktreeButton.action = #selector(showWorktrees)
        workspace.navigation.search.target = self; workspace.navigation.search.action = #selector(showProjectSearch)
        projectSearch.onDismiss = { [weak self] in self?.showFiles() }
        projectSearch.onChoose = { [weak self] root, match in
            guard let self, self.session.state?.root == root, !self.session.isSwitching,
                  self.session.state?.searchableFiles.contains(match.path) == true else { return }
            let editor = self.workspace.editor
            self.workspace.editorGroups.activate(editor, focus: true)
            self.openFile(match.path, diff: false, line: match.line, character: match.character, editor: editor, forceSource: true)
            self.workspace.explorer.select(match.path)
        }
        workspace.navigation.files.target = self; workspace.navigation.files.action = #selector(showFiles)
        workspace.navigation.changes.target = self; workspace.navigation.changes.action = #selector(showChanges)
        session.onIndexBusyChange = { [weak self] busy in
            guard let self else { return }
            self.workspace.explorer.setIndexBusy(busy)
            self.workspace.header.setBusy(busy || self.session.isSwitching)
            self.historySidebar?.setBusy(busy || self.session.isSwitching)
        }
        workspace.explorer.onIndexAction = { [weak self] action, target in self?.updateIndex(action, target: target) }
        workspace.explorer.onSelect = { [weak self] path, comparison in self?.openFile(path, diff: comparison != nil, comparison: comparison ?? .workingTree) }
        workspace.explorer.onReveal = { [weak self] path in
            guard let url = try? self?.session.reader?.files.safeURL(path) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        workspace.explorer.loadDirectory = { [weak self] path in
            guard let files = self?.session.reader?.files else { return [] }
            return try files.children(in: path)
        }
        workspace.explorer.onLoadError = { [weak self] error in self?.workspace.status.message.stringValue = error.localizedDescription }
        workspace.explorer.onExpandedDirectoriesChange = { [weak self] paths in
            self?.session.inspectedDirectories = paths
            self?.scheduleReadingSave()
        }
        workspace.editorGroups.editors.forEach(configureEditor)
        workspace.editorGroups.onEditorAdded = { [weak self] editor in self?.configureEditor(editor); self?.scheduleReadingSave() }
        workspace.editorGroups.onEditorRemoved = { [weak self] editor in
            guard let self else { return }
            self.scheduleReadingSave()
            self.session.invalidateDocument(scope: editor.readingID)
            if self.inspectionEditor === editor { self.inspection.dismiss(); self.inspectionEditor = nil }
            if self.workspace.editorGroups.editors.allSatisfy({ $0.activePath == nil }) { self.language.stop() }
            self.refreshLanguageStatus()
        }
        workspace.editorGroups.onActiveChanged = { [weak self] editor in
            guard let self else { return }
            self.scheduleReadingSave()
            self.inspectToken = UUID(); self.hoverRequest = UUID()
            self.inspection.dismiss()
            self.syncLanguage(for: editor)
            self.refreshLanguageStatus()
            self.refreshEditingStatus()
        }
        workspace.editorGroups.onSplitDocument = { [weak self] document, editor in
            self?.openFile(document.path, diff: document.comparison != nil, comparison: document.comparison ?? .workingTree, editor: editor)
        }
        inspection.onHoverDismiss = { [weak self] in self?.inspectionEditor?.right.text.clearInspectionFeedback() }
        inspection.onFindReferences = { [weak self] index in
            guard let self else { return }
            let editor = self.inspectionEditor ?? self.workspace.editor
            self.workspace.editorGroups.activate(editor)
            self.inspect(index: index, kind: "references", editor: editor)
        }
        language.onStatus = { [weak self] text in
            guard let self else { return }
            self.languageStatus = text
            self.refreshLanguageStatus()
            if text == "TypeScript · Ready", self.workspace.status.message.stringValue.hasPrefix("TypeScript") {
                self.workspace.status.message.stringValue = "Read Only"
                self.workspace.status.message.toolTip = nil
            }
        }
        language.onFailure = { [weak self] reason in
            self?.workspace.status.message.stringValue = reason
            self?.workspace.status.message.toolTip = reason
        }
        inspection.onStatus = { [weak self] text in self?.workspace.status.message.stringValue = text }
        inspection.onNavigate = { [weak self] location in
            guard let self else { return }
            if let editor = self.inspectionEditor { self.workspace.editorGroups.activate(editor) }
            self.navigate(location)
        }
        session.onOpen = { [weak self] state in
            guard let self else { return }
            self.history.record(state)
            self.applyState(state)
            self.historySidebar?.setBusy(false)
            if let error = self.history.persistenceError { self.workspace.status.message.stringValue = error }
            self.view.window?.representedURL = state.root
            self.view.window?.title = "\(state.root.lastPathComponent) — VCode"
        }
        session.onRefresh = { [weak self] state in
            guard let self else { return }
            self.history.update(state)
            self.applyState(state)
        }
        session.onError = { [weak self] error in
            self?.historySidebar?.setBusy(false)
            self?.workspace.status.message.stringValue = error.localizedDescription
        }
        if let error = history.persistenceError {
            workspace.status.message.stringValue = error
            workspace.status.message.toolTip = error
        }
    }

    private func applyState(_ state: WorkspaceState) {
        let previous = displayedState
        let changedRoot = previous?.root != state.root
        let saved = changedRoot ? history.readingSession(in: state.root) : nil
        if changedRoot {
            readingStateReady = false
            resetReading()
            treeSessions = saved?.trees ?? [:]
            changesOnly = saved?.changesOnly ?? changesOnly
            workspace.explorer.filter.stringValue = ""
            projectSearch.setActive(false); workspace.showSearch(false)
        }
        else if previous?.branch != state.branch {
            inspectToken = UUID(); hoverRequest = UUID()
            inspection.dismiss(); language.stop()
        }
        let renames = previous.map { state.renames(from: $0) } ?? [:]
        history.renameFiles(renames, in: state.root)
        projectSearch.setWorkspace(root: state.root, paths: state.searchableFiles)
        quickOpen?.update(paths: state.searchableFiles, recent: history.recentFiles(in: state.root))
        let renamedActive = workspace.editor.activePath.map { renames[$0] != nil } ?? false
        for editor in workspace.editorGroups.editors {
            editor.allowsNavigation = true
            editor.renamePaths(renames)
        }
        displayedState = state
        workspace.show(state, changesOnly: changesOnly)
        workspace.header.setBusy(session.isUpdatingIndex || session.isSwitching)
        updateHistorySidebar()
        if changedRoot {
            if let saved {
                workspace.restoreSidebarWidth(saved.sidebarWidth)
                workspace.editorGroups.restoreSession(Array(saved.groups.prefix(2)), active: saved.activeGroup, ratio: saved.splitRatio)
            }
            if let tree = treeSessions[changesOnly ? "changes" : "files"] { workspace.explorer.restoreSession(tree) }
        }
        readingStateReady = true
        for editor in workspace.editorGroups.editors {
            if let path = editor.activePath {
                if changedRoot {
                    openFile(path, diff: editor.activeComparison != nil, comparison: editor.activeComparison ?? .workingTree, editor: editor)
                } else {
                    loadFile(path, diff: editor.showingDiff, comparison: editor.activeComparison ?? .workingTree, preserveScroll: true, editor: editor)
                }
            }
        }
        refreshEditingStatus()
        if renamedActive, let path = workspace.editor.activePath { workspace.explorer.select(path, comparison: workspace.editor.activeComparison) }
        scheduleReadingSave()
    }

    private func configureEditor(_ editor: EditorView) {
        editor.onDraftActivated = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.workspace.editorGroups.activate(editor)
            self.session.invalidateDocument(scope: editor.readingID)
            self.inspectToken = UUID(); self.hoverRequest = UUID()
            self.dismissShortcuts(); self.dismissQuickOpen(); self.picker?.close()
            self.inspection.dismiss()
            self.refreshLanguageStatus()
            self.refreshEditingStatus()
        }
        editor.onSessionChanged = { [weak self] in self?.scheduleReadingSave() }
        editor.allowsNavigation = session.state != nil && !session.isSwitching
        editor.onRestoreLocation = { [weak self, weak editor] location in
            guard let self, let editor else { return }
            self.workspace.editorGroups.activate(editor, focus: true)
            self.openFile(location.document.path, diff: location.document.comparison != nil,
                comparison: location.document.comparison ?? .workingTree, editor: editor, restoring: location)
            self.workspace.explorer.select(location.document.path, comparison: location.document.comparison)
        }
        editor.onOpenFolder = { [weak self] in self?.openFolder() }
        editor.onSelectFile = { [weak self, weak editor] path, comparison in
            guard let self, let editor else { return }
            self.workspace.editorGroups.activate(editor)
            self.openFile(path, diff: comparison != nil, comparison: comparison ?? .workingTree, editor: editor)
        }
        editor.onLastTabClosed = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.scheduleReadingSave()
            self.session.invalidateDocument(scope: editor.readingID)
            if self.inspectionEditor === editor { self.inspection.dismiss() }
            if self.workspace.editorGroups.editors.count == 2 { self.workspace.editorGroups.close(editor) }
            else { self.language.stop(); self.inspectToken = UUID() }
            self.refreshLanguageStatus()
        }
        editor.onCursor = { [weak self, weak editor] position in
            guard let self, let editor, self.workspace.editor === editor else { return }
            self.workspace.status.message.stringValue = "Ln \(position.line + 1), Col \(position.character + 1)  ·  \(editor.isEditingDraft ? "Editable" : "Read Only")"
        }
        editor.right.text.onInspect = { [weak self, weak editor] index, kind in
            guard let self, let editor else { return }
            if kind != "hover" { self.workspace.editorGroups.activate(editor) }
            self.inspect(index: index, kind: kind, editor: editor)
        }
        editor.right.text.onDefinitionProbe = { [weak self, weak editor] index, completion in
            guard let self, let editor else { completion(false); return }
            self.querySymbol(index: index, kind: .definition, editor: editor) { [weak self] value in
                guard let self, let root = self.session.reader?.root, case .locations(let locations) = value else { completion(false); return }
                completion(locations.contains { self.canNavigate($0, root: root) })
            }
        }
        editor.right.text.onSymbolClick = { [weak self, weak editor] index, completion in
            guard let self, let editor else { completion([]); return }
            self.querySymbol(index: index, kind: .documentHighlight, editor: editor) { [weak editor] value in
                guard let editor, case .highlights(let occurrences) = value else { completion([]); return }
                completion(occurrences.compactMap { editor.right.characterRange(startLine: $0.startLine, startCharacter: $0.startCharacter, endLine: $0.endLine, endCharacter: $0.endCharacter) })
            }
        }
        editor.right.text.onHoverInvalidated = { [weak self, weak editor] in
            guard let self, let editor, self.inspectionEditor === editor else { return }
            self.hoverRequest = UUID(); self.inspection.dismissHover()
        }
        editor.right.text.onHoverExited = { [weak self, weak editor] in
            guard let self, let editor, self.inspectionEditor === editor else { return }
            self.hoverRequest = UUID(); self.inspection.dismissHoverWhenPointerLeaves()
        }
        editor.right.text.onHoverMoved = { [weak self, weak editor] point in
            guard let self, let editor, self.inspectionEditor === editor else { return }
            self.inspection.hoverPointerMoved(to: point)
        }
    }

    private func syncLanguage(for editor: EditorView) {
        guard let reader = session.reader, let path = editor.activePath, let source = editor.currentSource,
              language.supports(path), FileManager.default.fileExists(atPath: reader.root.appendingPathComponent(path).path) else { return }
        language.open(url: reader.root.appendingPathComponent(path), text: source, root: reader.root)
    }

    private func refreshEditingStatus() {
        guard workspace.editor.activeDocument != nil else { return }
        workspace.status.message.stringValue = workspace.editor.isEditingDraft ? "Editable text · ⌘S to save" : "Read Only"
    }

    private func refreshLanguageStatus() {
        if workspace.editor.isEditingDraft { workspace.status.language.stringValue = "Plain Text · Editable"; return }
        guard let path = workspace.editor.activePath else { workspace.status.language.stringValue = ""; return }
        workspace.status.language.stringValue = language.supports(path) ? languageStatus : path.hasSuffix(".py") ? "Python · Text preview" : "UTF-8"
    }

    @objc func newTextTab() { workspace.editor.newTextTab() }
    @objc func saveText() { workspace.editor.saveTextAs() }
    @objc func saveTextAs() { workspace.editor.saveTextAs(alwaysChoose: true) }

    @objc func openFolder() {
        dismissShortcuts()
        dismissCodeHover()
        dismissQuickOpen()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Folder"
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func open(_ folder: URL) {
        guard !session.isSwitching else { return }
        cancelExternalOpen()
        openWorkspace(folder)
    }

    private func openWorkspace(_ folder: URL, completion: ((Result<WorkspaceState, Error>) -> Void)? = nil) {
        saveReadingSession()
        readingStateReady = false
        historySidebar?.setBusy(true)
        dismissShortcuts()
        dismissQuickOpen()
        projectSearch.setActive(false); workspace.showSearch(false)
        workspace.navigation.search.isEnabled = false
        picker?.close()
        pickerRequest = UUID()
        inspection.dismiss()
        inspectToken = UUID()
        language.stop()
        workspace.status.message.stringValue = "Opening folder…"
        workspace.editorGroups.editors.forEach { $0.allowsNavigation = false }
        session.open(folder, completion: completion)
    }

    func openExternal(_ urls: [URL]) {
        externalURLs.append(contentsOf: urls)
        processExternalOpen()
    }

    private func cancelExternalOpen() {
        externalOpenToken = UUID(); externalURLs = []; externalOpenBusy = false
        externalOpenFailures = []
        workspace.dismissOpenNotice()
    }

    private func processExternalOpen() {
        guard !externalOpenBusy, !session.isSwitching, !externalURLs.isEmpty else { return }
        externalOpenBusy = true
        let url = externalURLs.removeFirst(), token = externalOpenToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ExternalOpenResolver.resolve(url) }
            DispatchQueue.main.async {
                guard let self, self.externalOpenToken == token else { return }
                switch result {
                case .failure(let error):
                    self.recordExternalOpenFailure(url, error: error)
                    self.finishExternalOpen()
                case .success(let target):
                    if let state = self.session.state, state.root.path == target.root.path {
                        self.showExternalDocument(target, in: state)
                        self.finishExternalOpen()
                    } else {
                        self.openWorkspace(target.root) { [weak self] result in
                            guard let self, self.externalOpenToken == token else { return }
                            switch result {
                            case .success(let state): self.showExternalDocument(target, in: state)
                            case .failure(let error): self.recordExternalOpenFailure(url, error: error)
                            }
                            self.finishExternalOpen()
                        }
                    }
                }
            }
        }
    }

    private func showExternalDocument(_ target: ExternalOpenTarget, in state: WorkspaceState) {
        guard let path = target.relativePath(in: state.root) else { return }
        openFile(path, diff: false)
        workspace.editorGroups.activate(workspace.editor, focus: true)
    }

    private func finishExternalOpen() {
        externalOpenBusy = false
        processExternalOpen()
        presentExternalOpenFailures()
    }

    private func recordExternalOpenFailure(_ url: URL, error: Error) {
        workspace.status.message.stringValue = "Cannot open \(url.lastPathComponent): \(error.localizedDescription)"
        let failure = ExternalOpenNotice.Failure(url: url, reason: error.localizedDescription)
        if !externalOpenFailures.contains(failure) { externalOpenFailures.append(failure) }
    }

    private func presentExternalOpenFailures() {
        guard !externalOpenBusy, externalURLs.isEmpty, !externalOpenFailures.isEmpty else { return }
        workspace.showOpenNotice(externalOpenFailures)
        view.window?.makeKeyAndOrderFront(nil)
    }
    @objc func refresh() { session.refresh() }
    @objc func showFiles() { changeSidebar(false) }
    @objc func showChanges() { changeSidebar(true) }
    private func changeSidebar(_ changes: Bool) {
        dismissShortcuts()
        let leavingSearch = !workspace.searchHost.isHidden
        projectSearch.setActive(false); workspace.showSearch(false)
        let changedMode = changesOnly != changes
        if changedMode { treeSessions[changesOnly ? "changes" : "files"] = workspace.explorer.captureSession() }
        changesOnly = changes
        workspace.navigation.select(changes: changes)
        if let state = session.state {
            workspace.explorer.show(state, changesOnly: changes)
            if changedMode {
                workspace.explorer.restoreSession(treeSessions[changes ? "changes" : "files"] ?? FileTreeReadingState(expanded: [], collapsed: [], selection: nil, query: "", scrollOffset: 0))
            }
        }
        scheduleReadingSave()
        if leavingSearch { workspace.editorGroups.activate(workspace.editor, focus: true) }
    }

    func openFile(_ path: String, diff: Bool, comparison: GitComparison = .workingTree, line: Int? = nil, character: Int = 0, highlightDestination: Bool = false, editor: EditorView? = nil, restoring location: ReadingLocation? = nil, forceSource: Bool = false) {
        guard let state = session.state, !session.isSwitching else { return }
        let editor = editor ?? workspace.editor
        inspectToken = UUID()
        inspection.dismiss()
        if state.searchableFiles.contains(path) { history.recordFile(path, in: state.root) }
        editor.prepare(path: path, diff: diff, isGit: state.isGit, comparison: comparison, restoring: location, recordNavigation: location == nil, forceSource: forceSource)
        refreshLanguageStatus()
        if workspace.editor === editor { refreshEditingStatus() }
        loadFile(path, diff: editor.showingDiff, comparison: comparison, position: line.map { ($0, character) }, highlightDestination: highlightDestination, editor: editor)
    }

    private func loadFile(_ path: String, diff: Bool, comparison: GitComparison = .workingTree, preserveScroll: Bool = false, position: (Int, Int)? = nil, highlightDestination: Bool = false, editor: EditorView) {
        session.read(path, diff: diff, comparison: comparison, scope: editor.readingID) { [weak self, weak editor] result in
            guard let self, let editor, self.workspace.editorGroups.editors.contains(where: { $0 === editor }) else { return }
            switch result {
            case .success(let snapshot):
                editor.show(snapshot, diff: diff, preserveScroll: preserveScroll, position: position, highlightDestination: highlightDestination)
                if let reader = self.session.reader, snapshot.message == nil, self.language.supports(path), FileManager.default.fileExists(atPath: reader.root.appendingPathComponent(path).path) {
                    self.language.open(url: reader.root.appendingPathComponent(path), text: snapshot.after, root: reader.root)
                } else {
                    if self.workspace.editor === editor { self.refreshLanguageStatus() }
                }
                if self.view.window?.firstResponder === editor {
                    self.view.window?.makeFirstResponder(editor.showingMarkdownPreview ? editor.markdown.text : editor.right.text)
                }
            case .failure(let error): editor.showError(error)
            }
        }
    }

    private func inspect(index: Int, kind: String, editor: EditorView) {
        guard let kind = InspectionKind(rawValue: kind), let root = session.reader?.root, let path = editor.activePath, language.supports(path), let position = editor.right.position(at: index) else { return }
        if kind == .hover {
            guard quickOpen == nil, picker?.isShown != true, view.window?.attachedSheet == nil else { return }
        }
        historySidebar?.details.dismiss()
        if kind == .hover { hoverRequest = UUID() } else { inspectToken = UUID() }
        inspectionEditor = editor
        syncLanguage(for: editor)
        let token = inspectToken
        let hoverToken = hoverRequest
        let source = editor.right.text.string
        let comparison = editor.activeComparison
        let documentURL = root.appendingPathComponent(path).standardizedFileURL
        let identifier = CodeTextView.identifier(in: source as NSString, at: index)
        if kind == .references { workspace.status.message.stringValue = "Finding references…"; inspection.dismiss() }
        language.inspect(url: root.appendingPathComponent(path), line: position.line, character: position.character, kind: kind) { [weak self, weak editor] result in
            guard let self, let editor, self.inspectToken == token, self.inspectionEditor === editor, editor.activePath == path,
                  self.session.reader?.root == root, !self.session.isSwitching,
                  editor.activeComparison == comparison, editor.right.text.string == source,
                  self.workspace.editorGroups.editors.contains(where: { $0 === editor }),
                  kind != .hover || self.hoverRequest == hoverToken else { return }
            switch result {
            case .failure(let error): if kind != .hover { self.workspace.status.message.stringValue = error.localizedDescription }
            case .success(let value):
                // Definition results identify the declaration semantically. The
                // mouse can hit any UTF-16 position inside its identifier, so an
                // exact click/start comparison would miss most declaration clicks.
                if kind == .definition, let identifier, case .locations(let locations) = value,
                   locations.contains(where: { location in
                       guard location.url.standardizedFileURL == documentURL,
                             let target = editor.right.characterRange(startLine: location.line, startCharacter: location.character,
                                 endLine: location.line, endCharacter: location.character + 1) else { return false }
                       return NSLocationInRange(target.location, identifier)
                   }) {
                    editor.right.text.cancelNavigationFlash()
                    self.inspect(index: index, kind: "references", editor: editor)
                    return
                }
                if kind == .references, case .locations(let locations) = value {
                    self.workspace.status.message.stringValue = "\(Set(locations).count) references"
                }
                let lines = editor.right.lines.filter { $0.number != nil }.map(\.text)
                self.inspection.show(value, kind: kind, index: index, textView: editor.right.text, root: root, currentDocument: (root.appendingPathComponent(path), lines))
            }
        }
    }

    private func querySymbol(index: Int, kind: InspectionKind, editor: EditorView, completion: @escaping (LanguageInspection?) -> Void) {
        guard quickOpen == nil, picker?.isShown != true, view.window?.attachedSheet == nil,
              !session.isSwitching, let root = session.reader?.root, let path = editor.activePath,
              language.supports(path), let position = editor.right.position(at: index) else { completion(nil); return }
        let source = editor.right.text.string
        syncLanguage(for: editor)
        language.inspect(url: root.appendingPathComponent(path), line: position.line, character: position.character, kind: kind) { [weak self, weak editor] result in
            guard let self, let editor, self.session.reader?.root == root, editor.activePath == path,
                  editor.right.text.string == source, !self.session.isSwitching,
                  self.workspace.editorGroups.editors.contains(where: { $0 === editor }) else { completion(nil); return }
            switch result {
            case .success(let value): completion(value)
            case .failure(let error):
                if kind == .documentHighlight { self.workspace.status.message.stringValue = error.localizedDescription }
                completion(nil)
            }
        }
    }

    private func canNavigate(_ location: CodeLocation, root: URL) -> Bool {
        let path = location.url.standardizedFileURL.path
        return path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: path)
    }

    private func navigate(_ location: CodeLocation) {
        guard let root = session.reader?.root else { return }
        let path = location.url.standardizedFileURL.path
        guard path.hasPrefix(root.path + "/") else { workspace.status.message.stringValue = "Definition is outside this folder: \(location.url.lastPathComponent)"; return }
        let relative = String(path.dropFirst(root.path.count + 1))
        changeSidebar(false)
        openFile(relative, diff: false, line: location.line, character: location.character, highlightDestination: true)
        workspace.explorer.select(relative)
    }

    @objc func closeTab() {
        if shortcutsPicker != nil { dismissShortcuts(restoreFocus: true); return }
        guard !workspace.editor.closeActiveTab() else { return }
        if workspace.editorGroups.editors.count == 2 { workspace.editorGroups.close(workspace.editor) }
        else { view.window?.performClose(nil) }
    }
    @objc func splitEditorRight() { workspace.editorGroups.splitActiveEditor() }
    @objc func goBack() { workspace.editor.goBack() }
    @objc func goForward() { workspace.editor.goForward() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(newTextTab) { return session.state != nil && !session.isSwitching }
        if item.action == #selector(saveText) || item.action == #selector(saveTextAs) { return workspace.editor.isEditingDraft && !session.isSwitching }
        if item.action == #selector(showQuickOpen) || item.action == #selector(showProjectSearch) { return session.state != nil && !session.isSwitching }
        if item.action == #selector(findInEditor) || item.action == #selector(findNext) || item.action == #selector(findPrevious) {
            return workspace.editor.canFind && !session.isSwitching
        }
        if item.action == #selector(goBack) { return !session.isSwitching && workspace.editor.canGoBack }
        if item.action == #selector(goForward) { return !session.isSwitching && workspace.editor.canGoForward }
        return true
    }
    @objc func nextChange() { workspace.editor.navigateChange(forward: true) }
    @objc func previousChange() { workspace.editor.navigateChange(forward: false) }
    @objc func findInEditor() { dismissCodeHover(); dismissQuickOpen(); dismissShortcuts(); workspace.editor.performFind(.showFindInterface) }
    @objc func findNext() { workspace.editor.performFind(.nextMatch) }
    @objc func findPrevious() { workspace.editor.performFind(.previousMatch) }
    @objc func showBranches() { showPicker(.branches, anchor: workspace.header.branchButton) }
    @objc func showWorktrees() { showPicker(.worktrees, anchor: workspace.header.worktreeButton) }

    @objc func showProjectSearch() {
        guard session.state != nil, !session.isSwitching else { return }
        dismissShortcuts()
        dismissCodeHover(); dismissQuickOpen(); picker?.close(); pickerRequest = UUID()
        workspace.showSearch(true); projectSearch.setActive(true)
        projectSearch.query.selectText(nil)
    }

    @objc func showQuickOpen() {
        guard let state = session.state, !session.isSwitching else { return }
        dismissShortcuts()
        dismissCodeHover(); picker?.close(); pickerRequest = UUID()
        if let quickOpen { view.window?.makeFirstResponder(quickOpen.filter); quickOpen.filter.selectText(nil); return }
        let controller = QuickOpenPicker(paths: state.searchableFiles, recent: history.recentFiles(in: state.root))
        let editor = workspace.editor
        addChild(controller); workspace.add(controller.view)
        let width = controller.view.widthAnchor.constraint(equalToConstant: 760); width.priority = .defaultHigh
        let height = controller.view.heightAnchor.constraint(equalToConstant: 460); height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            controller.view.centerXAnchor.constraint(equalTo: workspace.centerXAnchor), controller.view.topAnchor.constraint(equalTo: workspace.header.bottomAnchor, constant: 8),
            controller.view.leadingAnchor.constraint(greaterThanOrEqualTo: workspace.leadingAnchor, constant: 16), controller.view.trailingAnchor.constraint(lessThanOrEqualTo: workspace.trailingAnchor, constant: -16),
            controller.view.heightAnchor.constraint(lessThanOrEqualTo: workspace.heightAnchor, constant: -104), width, height
        ])
        controller.onDismiss = { [weak self, weak editor] in
            self?.dismissQuickOpen()
            if let self, let editor { self.workspace.editorGroups.activate(editor, focus: true) }
        }
        controller.onChoose = { [weak self, weak editor] path in
            guard let self, let editor, self.session.state?.root == state.root,
                  self.workspace.editorGroups.editors.contains(where: { $0 === editor }),
                  self.session.state?.searchableFiles.contains(path) == true else { return }
            self.dismissQuickOpen(); self.workspace.editorGroups.activate(editor, focus: true)
            self.view.window?.makeFirstResponder(editor)
            self.openFile(path, diff: false, editor: editor)
            self.workspace.explorer.select(path)
        }
        quickOpen = controller
        workspace.layoutSubtreeIfNeeded(); view.window?.makeFirstResponder(controller.filter)
        quickOpenMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak controller] event in
            guard let self, let controller, event.window === self.view.window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { controller.onDismiss?(); return nil }
            } else if !controller.view.bounds.contains(controller.view.convert(event.locationInWindow, from: nil)) { self.dismissQuickOpen() }
            return event
        }
    }

    private func dismissQuickOpen() {
        if let quickOpenMonitor { NSEvent.removeMonitor(quickOpenMonitor); self.quickOpenMonitor = nil }
        quickOpen?.view.removeFromSuperview(); quickOpen?.removeFromParent(); quickOpen = nil
    }

    private func configureHistorySidebar() {
        let sidebar = WorkspaceHistorySidebar(entries: history.entries, current: nil, available: { [history] in history.isAvailable($0) })
        historySidebar = sidebar
        addChild(sidebar)
        workspace.recentHost.add(sidebar.view)
        Theme.pin(sidebar.view, to: workspace.recentHost)
        sidebar.onInteract = { [weak self] in
            self?.dismissShortcuts(); self?.dismissQuickOpen(); self?.dismissCodeHover()
            self?.picker?.close(); self?.pickerRequest = UUID()
        }
        sidebar.onChoose = { [weak self] root in
            guard let self, !self.session.isSwitching else { return }
            guard self.history.isAvailable(root) else {
                self.workspace.status.message.stringValue = "This recent folder is no longer available: " + root.path
                return
            }
            self.open(root)
        }
        sidebar.onRemove = { [weak self] root in
            guard let self, !self.session.isSwitching else { return }
            self.history.removeRecent(root)
            self.updateHistorySidebar()
        }
        sidebar.onClear = { [weak self] in
            guard let self, !self.session.isSwitching else { return }
            self.history.clearRecents()
            self.updateHistorySidebar()
        }
        workspace.restoreRecentSidebarWidth(history.recentSidebarWidth)
        workspace.onRecentWidthChanged = { [weak self] width in
            guard let self else { return }
            self.historyWidthSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.history.saveRecentSidebarWidth(width) }
            self.historyWidthSave = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func updateHistorySidebar() {
        historySidebar?.update(entries: history.entries, current: session.state?.root)
        if let error = history.persistenceError { workspace.status.message.stringValue = error }
    }

    @objc func showHistory() {
        guard !session.isSwitching else { return }
        historySidebar.onInteract?()
        workspace.restoreRecentSidebarWidth(max(200, workspace.recentSidebarWidth))
        workspace.layoutSubtreeIfNeeded()
        historySidebar.view.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(historySidebar.filter)
    }

    private func showPicker(_ kind: GitDestinationPicker.Kind, anchor: NSButton) {
        guard session.state?.isGit == true, !session.isSwitching, !session.isUpdatingIndex else { return }
        dismissShortcuts()
        dismissCodeHover()
        dismissQuickOpen()
        picker?.close()
        let controller = GitDestinationPicker(kind: kind)
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 560, height: 440)
        popover.behavior = .transient
        popover.animates = false
        controller.onChoose = { [weak self, weak controller] destination in
            self?.activate(destination) { result in
                switch result {
                case .success: self?.picker?.close()
                case .failure(let error): controller?.showError(error)
                }
            }
            controller?.setBusy(true)
        }
        controller.onRefresh = { [weak self, weak controller] in if let controller { self?.loadDestinations(into: controller) } }
        picker = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        loadDestinations(into: controller)
    }

    private func loadDestinations(into picker: GitDestinationPicker) {
        pickerRequest = UUID()
        let token = pickerRequest
        session.destinations { [weak self, weak picker] result in
            guard self?.pickerRequest == token else { return }
            switch result {
            case .success(let destinations): picker?.show(destinations)
            case .failure(let error): picker?.showError(error)
            }
        }
    }

    func updateIndex(_ action: GitIndexAction, target: GitChangeTarget) {
        guard session.state?.isGit == true, !session.isSwitching, !session.isUpdatingIndex else { return }
        dismissCodeHover()
        workspace.status.message.stringValue = action == .stage ? "Staging changes…" : "Unstaging changes…"
        session.updateIndex(action, target: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.workspace.status.message.stringValue = action == .stage ? "Changes staged" : "Changes unstaged"
                self.workspace.status.message.toolTip = nil
            case .failure(let error):
                self.workspace.status.message.stringValue = error.localizedDescription
                self.workspace.status.message.toolTip = error.localizedDescription
            }
        }
    }

    func activate(_ destination: GitDestination, completion: @escaping (Result<WorkspaceState, Error>) -> Void) {
        guard !session.isSwitching, !session.isUpdatingIndex, session.reader != nil else { return }
        cancelExternalOpen()
        saveReadingSession()
        readingStateReady = false
        dismissShortcuts()
        dismissQuickOpen(); projectSearch.setActive(false)
        inspectToken = UUID()
        session.invalidateDocument()
        inspection.dismiss()
        language.stop()
        workspace.status.language.stringValue = ""
        historySidebar?.setBusy(true)
        workspace.header.setBusy(true)
        workspace.navigation.search.isEnabled = false
        workspace.explorer.outline.isEnabled = false
        workspace.status.message.stringValue = "Switching repository context…"
        workspace.editorGroups.editors.forEach { $0.allowsNavigation = false }
        session.activate(destination) { [weak self] result in
            if let self, !self.workspace.searchHost.isHidden { self.projectSearch.setActive(true) }
            self?.readingStateReady = self?.displayedState != nil
            self?.workspace.editorGroups.editors.forEach { $0.allowsNavigation = true }
            self?.historySidebar?.setBusy(false)
            self?.workspace.header.setBusy(false)
            self?.processExternalOpen()
            self?.workspace.navigation.search.isEnabled = self?.session.state != nil
            self?.workspace.explorer.outline.isEnabled = true
            if case .failure(let error) = result { self?.workspace.status.message.stringValue = error.localizedDescription }
            completion(result)
        }
    }

    private func resetReading() {
        inspectToken = UUID()
        session.invalidateDocument()
        inspection.dismiss()
        language.stop()
        workspace.editorGroups.reset()
        workspace.status.language.stringValue = ""
    }
    private func dismissCodeHover() {
        historySidebar?.details.dismiss()
        hoverRequest = UUID()
        workspace.editor.right.text.cancelInspection()
        inspection.dismissHover()
    }
    func shutdown() {
        cancelExternalOpen()
        historySidebar?.details.dismiss()
        saveReadingSession()
        readingStateReady = false
        dismissShortcuts(); cancelShortcutChord()
        if let shortcutKeyMonitor { NSEvent.removeMonitor(shortcutKeyMonitor); self.shortcutKeyMonitor = nil }
        if let shortcutFocusObserver { NotificationCenter.default.removeObserver(shortcutFocusObserver); self.shortcutFocusObserver = nil }
        dismissQuickOpen(); projectSearch.cancel(); picker?.close(); session.close(); inspection.dismiss(); language.stop()
    }

    private func configureReadingPersistence() {
        let names: [Notification.Name] = [NSTextView.didChangeSelectionNotification, NSView.boundsDidChangeNotification,
            NSOutlineView.itemDidExpandNotification, NSOutlineView.itemDidCollapseNotification,
            NSOutlineView.selectionDidChangeNotification, NSSplitView.didResizeSubviewsNotification,
            NSControl.textDidChangeNotification]
        for name in names {
            readingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, let view = note.object as? NSView, view.isDescendant(of: self.workspace) else { return }
                self.scheduleReadingSave()
            })
        }
    }

    private func scheduleReadingSave() {
        guard readingStateReady else { return }
        readingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveReadingSession() }
        readingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveReadingSession() {
        readingSave?.cancel(); readingSave = nil
        historyWidthSave?.cancel(); historyWidthSave = nil
        history.saveRecentSidebarWidth(workspace.preferredRecentSidebarWidth)
        guard readingStateReady, let state = displayedState else { return }
        treeSessions[changesOnly ? "changes" : "files"] = workspace.explorer.captureSession()
        let groups = workspace.editorGroups
        let saved = WorkspaceReadingSession(groups: groups.editors.map { $0.captureSession() },
            activeGroup: groups.editors.firstIndex(where: { $0 === groups.activeEditor }) ?? 0,
            splitRatio: groups.splitRatio, sidebarWidth: workspace.sidebarWidth, changesOnly: changesOnly, trees: treeSessions)
        history.saveReadingSession(saved, in: state.root)
    }

    private func configureShortcutKeys() {
        shortcutKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleShortcutKey(event) ? nil : event
        }
        shortcutFocusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? NSWindow) === self.view.window else { return }
            self.cancelShortcutChord()
        }
    }

    func handleShortcutKey(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window, window.attachedSheet == nil else { cancelShortcutChord(); return false }
        guard event.type == .keyDown else { cancelShortcutChord(); return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let deadline = shortcutChord.deadline, now > deadline { cancelShortcutChord() }
        switch shortcutChord.handle(event, now: now) {
        case .passThrough: cancelShortcutChord(); return false
        case .cancelled: cancelShortcutChord(); return true
        case .open: cancelShortcutChord(); showKeyboardShortcuts(); return true
        case .waiting:
            if shortcutChordReset == nil {
                shortcutMessageBeforeChord = workspace.status.message.stringValue
                workspace.status.message.stringValue = shortcutChordHint
                let reset = DispatchWorkItem { [weak self] in self?.cancelShortcutChord() }
                shortcutChordReset = reset
                DispatchQueue.main.asyncAfter(deadline: .now() + KeyboardShortcutChord.timeout, execute: reset)
            }
            return true
        }
    }

    private func cancelShortcutChord() {
        shortcutChord.cancel()
        shortcutChordReset?.cancel(); shortcutChordReset = nil
        if let previous = shortcutMessageBeforeChord, workspace.status.message.stringValue == shortcutChordHint { workspace.status.message.stringValue = previous }
        shortcutMessageBeforeChord = nil
    }

    @objc func showKeyboardShortcuts() {
        cancelShortcutChord()
        guard let window = view.window else { return }
        if let shortcutsPicker { window.makeFirstResponder(shortcutsPicker.filter); shortcutsPicker.filter.selectText(nil); return }
        dismissCodeHover(); dismissQuickOpen(); picker?.close(); pickerRequest = UUID()
        let focused = window.firstResponder as? NSView
        if let fieldEditor = focused as? NSTextView, fieldEditor.isFieldEditor { shortcutPreviousFocus = fieldEditor.delegate as? NSView }
        else { shortcutPreviousFocus = focused }
        let controller = KeyboardShortcutsController(entries: KeyboardShortcutCatalog.entries(in: NSApp.mainMenu))
        addChild(controller); workspace.add(controller.view)
        let width = controller.view.widthAnchor.constraint(equalToConstant: 760); width.priority = .defaultHigh
        let height = controller.view.heightAnchor.constraint(equalToConstant: 560); height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            controller.view.centerXAnchor.constraint(equalTo: workspace.centerXAnchor), controller.view.topAnchor.constraint(equalTo: workspace.header.bottomAnchor, constant: 8),
            controller.view.leadingAnchor.constraint(greaterThanOrEqualTo: workspace.leadingAnchor, constant: 16), controller.view.trailingAnchor.constraint(lessThanOrEqualTo: workspace.trailingAnchor, constant: -16),
            controller.view.heightAnchor.constraint(lessThanOrEqualTo: workspace.heightAnchor, constant: -104), width, height
        ])
        controller.onDismiss = { [weak self] in self?.dismissShortcuts(restoreFocus: true) }
        shortcutsPicker = controller
        workspace.layoutSubtreeIfNeeded(); window.makeFirstResponder(controller.filter)
        shortcutsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak controller] event in
            guard let self, let controller, event.window === self.view.window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismissShortcuts(restoreFocus: true); return nil }
            } else if !controller.view.bounds.contains(controller.view.convert(event.locationInWindow, from: nil)) { self.dismissShortcuts() }
            return event
        }
    }

    private func dismissShortcuts(restoreFocus: Bool = false) {
        if let shortcutsMonitor { NSEvent.removeMonitor(shortcutsMonitor); self.shortcutsMonitor = nil }
        guard let shortcutsPicker else { return }
        view.window?.makeFirstResponder(nil)
        shortcutsPicker.view.removeFromSuperview(); shortcutsPicker.removeFromParent(); self.shortcutsPicker = nil
        if restoreFocus {
            if let previous = shortcutPreviousFocus, previous.isDescendant(of: workspace), !previous.isHiddenOrHasHiddenAncestor {
                view.window?.makeFirstResponder(previous)
            } else { workspace.editorGroups.activate(workspace.editor, focus: true) }
        }
        shortcutPreviousFocus = nil
    }
}
