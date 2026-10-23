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
    private let history: WorkspaceHistoryStore
    private var historyPicker: WorkspaceHistoryPicker?
    private var historyMonitor: Any?

    init(history: WorkspaceHistoryStore = WorkspaceHistoryStore(), inspection: InspectionPresenter = InspectionPresenter()) {
        self.history = history
        self.inspection = inspection
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = workspace
        configureActions()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let historyMonitor { NSEvent.removeMonitor(historyMonitor) }
        language.stop()
    }

    private func configureActions() {
        history.onError = { [weak self] message in
            self?.workspace.status.message.stringValue = message
            self?.workspace.status.message.toolTip = message
        }
        workspace.header.openButton.target = self; workspace.header.openButton.action = #selector(openFolder)
        workspace.header.branchButton.target = self; workspace.header.branchButton.action = #selector(showBranches)
        workspace.header.worktreeButton.target = self; workspace.header.worktreeButton.action = #selector(showWorktrees)
        workspace.header.historyButton.target = self; workspace.header.historyButton.action = #selector(showHistory)
        workspace.navigation.files.target = self; workspace.navigation.files.action = #selector(showFiles)
        workspace.navigation.changes.target = self; workspace.navigation.changes.action = #selector(showChanges)
        workspace.explorer.onSelect = { [weak self] path, comparison in self?.openFile(path, diff: comparison != nil, comparison: comparison ?? .workingTree) }
        workspace.explorer.onReveal = { [weak self] path in
            guard let url = try? self?.session.reader?.files.safeURL(path) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        workspace.editorGroups.editors.forEach(configureEditor)
        workspace.editorGroups.onEditorAdded = { [weak self] editor in self?.configureEditor(editor) }
        workspace.editorGroups.onEditorRemoved = { [weak self] editor in
            guard let self else { return }
            self.session.invalidateDocument(scope: editor.readingID)
            if self.inspectionEditor === editor { self.inspection.dismiss(); self.inspectionEditor = nil }
            if self.workspace.editorGroups.editors.allSatisfy({ $0.activePath == nil }) { self.language.stop() }
            self.refreshLanguageStatus()
        }
        workspace.editorGroups.onActiveChanged = { [weak self] editor in
            guard let self else { return }
            self.inspectToken = UUID(); self.hoverRequest = UUID()
            self.inspection.dismiss()
            self.syncLanguage(for: editor)
            self.refreshLanguageStatus()
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
            if let error = self.history.persistenceError { self.workspace.status.message.stringValue = error }
            self.view.window?.representedURL = state.root
            self.view.window?.title = "\(state.root.lastPathComponent) — VCode"
        }
        session.onRefresh = { [weak self] state in
            guard let self else { return }
            self.history.update(state)
            self.applyState(state)
        }
        session.onError = { [weak self] error in self?.workspace.status.message.stringValue = error.localizedDescription }
        if let error = history.persistenceError {
            workspace.status.message.stringValue = error
            workspace.status.message.toolTip = error
        }
    }

    private func applyState(_ state: WorkspaceState) {
        let previous = displayedState
        if previous?.root != state.root { resetReading() }
        else if previous?.branch != state.branch {
            inspectToken = UUID(); hoverRequest = UUID()
            inspection.dismiss(); language.stop()
        }
        let renames = previous.map { state.renames(from: $0) } ?? [:]
        let renamedActive = workspace.editor.activePath.map { renames[$0] != nil } ?? false
        for editor in workspace.editorGroups.editors {
            editor.allowsNavigation = true
            editor.renamePaths(renames)
        }
        displayedState = state
        workspace.show(state, changesOnly: changesOnly)
        for editor in workspace.editorGroups.editors {
            if let path = editor.activePath {
                loadFile(path, diff: editor.showingDiff, comparison: editor.activeComparison ?? .workingTree, preserveScroll: true, editor: editor)
            }
        }
        if renamedActive, let path = workspace.editor.activePath { workspace.explorer.select(path, comparison: workspace.editor.activeComparison) }
    }

    private func configureEditor(_ editor: EditorView) {
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
            self.session.invalidateDocument(scope: editor.readingID)
            if self.inspectionEditor === editor { self.inspection.dismiss() }
            if self.workspace.editorGroups.editors.count == 2 { self.workspace.editorGroups.close(editor) }
            else { self.language.stop(); self.inspectToken = UUID() }
            self.refreshLanguageStatus()
        }
        editor.onCursor = { [weak self, weak editor] position in
            guard let self, let editor, self.workspace.editor === editor else { return }
            self.workspace.status.message.stringValue = "Ln \(position.line + 1), Col \(position.character + 1)  ·  Read Only"
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

    private func refreshLanguageStatus() {
        guard let path = workspace.editor.activePath else { workspace.status.language.stringValue = ""; return }
        workspace.status.language.stringValue = language.supports(path) ? languageStatus : path.hasSuffix(".py") ? "Python · Text preview" : "UTF-8"
    }

    @objc func openFolder() {
        dismissCodeHover()
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
        dismissHistory()
        picker?.close()
        pickerRequest = UUID()
        inspection.dismiss()
        inspectToken = UUID()
        language.stop()
        workspace.status.message.stringValue = "Opening folder…"
        workspace.editorGroups.editors.forEach { $0.allowsNavigation = false }
        session.open(folder)
    }
    @objc func refresh() { session.refresh() }
    @objc func showFiles() { changeSidebar(false) }
    @objc func showChanges() { changeSidebar(true) }
    private func changeSidebar(_ changes: Bool) {
        changesOnly = changes
        workspace.navigation.select(changes: changes)
        if let state = session.state { workspace.explorer.show(state, changesOnly: changes) }
    }

    func openFile(_ path: String, diff: Bool, comparison: GitComparison = .workingTree, line: Int? = nil, character: Int = 0, highlightDestination: Bool = false, editor: EditorView? = nil, restoring location: ReadingLocation? = nil) {
        guard let state = session.state, !session.isSwitching else { return }
        let editor = editor ?? workspace.editor
        inspectToken = UUID()
        inspection.dismiss()
        editor.prepare(path: path, diff: diff, isGit: state.isGit, comparison: comparison, restoring: location, recordNavigation: location == nil)
        refreshLanguageStatus()
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
            guard historyPicker == nil, picker?.isShown != true, view.window?.attachedSheet == nil else { return }
        }
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
        guard historyPicker == nil, picker?.isShown != true, view.window?.attachedSheet == nil,
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
        guard !workspace.editor.closeActiveTab() else { return }
        if workspace.editorGroups.editors.count == 2 { workspace.editorGroups.close(workspace.editor) }
        else { view.window?.performClose(nil) }
    }
    @objc func splitEditorRight() { workspace.editorGroups.splitActiveEditor() }
    @objc func goBack() { workspace.editor.goBack() }
    @objc func goForward() { workspace.editor.goForward() }
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(goBack) { return !session.isSwitching && workspace.editor.canGoBack }
        if item.action == #selector(goForward) { return !session.isSwitching && workspace.editor.canGoForward }
        return true
    }
    @objc func nextChange() { workspace.editor.navigateChange(forward: true) }
    @objc func previousChange() { workspace.editor.navigateChange(forward: false) }
    @objc func showBranches() { showPicker(.branches, anchor: workspace.header.branchButton) }
    @objc func showWorktrees() { showPicker(.worktrees, anchor: workspace.header.worktreeButton) }

    @objc func showHistory() {
        guard !session.isSwitching else { return }
        dismissCodeHover()
        if historyPicker != nil { dismissHistory(); return }
        picker?.close()
        pickerRequest = UUID()
        let controller = WorkspaceHistoryPicker(entries: history.entries, current: session.state?.root, available: { [history] in history.isAvailable($0) })
        addChild(controller)
        let surface = controller.view
        workspace.add(surface)
        NSLayoutConstraint.activate([
            surface.trailingAnchor.constraint(equalTo: workspace.trailingAnchor, constant: -16),
            surface.topAnchor.constraint(equalTo: workspace.header.bottomAnchor),
            surface.widthAnchor.constraint(equalToConstant: 560), surface.heightAnchor.constraint(equalToConstant: controller.preferredHeight)
        ])
        controller.onChoose = { [weak self] root in
            guard let self else { return }
            guard self.history.isAvailable(root) else {
                self.workspace.status.message.stringValue = "This recent folder is no longer available: " + root.path
                return
            }
            self.open(root)
        }
        controller.onDismiss = { [weak self] in self?.dismissHistory() }
        historyPicker = controller
        workspace.header.historyButton.isSelected = true
        workspace.layoutSubtreeIfNeeded()
        view.window?.makeFirstResponder(controller.filter)
        historyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak controller] event in
            guard let self, let controller, event.window === self.view.window else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.dismissHistory(); return nil }
            } else {
                // Native title-bar interactions activate or move the window; keep
                // the panel open until the user clicks elsewhere in its content.
                if event.locationInWindow.y > (event.window?.contentLayoutRect.maxY ?? .infinity) { return event }
                let point = controller.view.convert(event.locationInWindow, from: nil)
                if !controller.view.bounds.contains(point) {
                    // Leave the header button to toggle the panel exactly once.
                    let button = self.workspace.header.historyButton
                    if !button.bounds.contains(button.convert(event.locationInWindow, from: nil)) { self.dismissHistory() }
                }
            }
            return event
        }
    }

    private func dismissHistory() {

        if let historyMonitor { NSEvent.removeMonitor(historyMonitor); self.historyMonitor = nil }
        historyPicker?.view.removeFromSuperview()
        historyPicker?.removeFromParent()
        historyPicker = nil
        workspace.header.historyButton.isSelected = false
    }

    private func showPicker(_ kind: GitDestinationPicker.Kind, anchor: NSButton) {
        guard session.state?.isGit == true, !session.isSwitching else { return }
        dismissCodeHover()
        dismissHistory()
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

    func activate(_ destination: GitDestination, completion: @escaping (Result<WorkspaceState, Error>) -> Void) {
        guard !session.isSwitching, session.reader != nil else { return }
        inspectToken = UUID()
        session.invalidateDocument()
        inspection.dismiss()
        language.stop()
        workspace.status.language.stringValue = ""
        workspace.header.setBusy(true)
        workspace.explorer.outline.isEnabled = false
        workspace.status.message.stringValue = "Switching repository context…"
        workspace.editorGroups.editors.forEach { $0.allowsNavigation = false }
        session.activate(destination) { [weak self] result in
            self?.workspace.editorGroups.editors.forEach { $0.allowsNavigation = true }
            self?.workspace.header.setBusy(false)
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
        hoverRequest = UUID()
        workspace.editor.right.text.cancelInspection()
        inspection.dismissHover()
    }
    func shutdown() { dismissHistory(); picker?.close(); session.close(); inspection.dismiss(); language.stop() }
}
