import AppKit

final class WorkspaceController: NSViewController {
    private let workspace = WorkspaceView()
    private let session = WorkspaceSession()
    private let language = LanguageService()
    private let inspection: InspectionPresenter
    private var changesOnly = false
    private var inspectToken = UUID()
    private var hoverRequest = UUID()
    private var observer: NSObjectProtocol?
    private var picker: NSPopover?
    private var pickerRequest = UUID()
    private var displayedBranch: String?
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
        workspace.header.refreshButton.target = self; workspace.header.refreshButton.action = #selector(refresh)
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
        workspace.editor.onOpenFolder = { [weak self] in self?.openFolder() }
        workspace.editor.onSelectFile = { [weak self] path, comparison in self?.openFile(path, diff: comparison != nil, comparison: comparison ?? .workingTree) }
        workspace.editor.onLastTabClosed = { [weak self] in
            self?.session.invalidateDocument(); self?.inspection.dismiss(); self?.language.stop(); self?.inspectToken = UUID(); self?.workspace.status.language.stringValue = ""
        }
        workspace.editor.onCursor = { [weak self] position in self?.workspace.status.message.stringValue = "Ln \(position.line + 1), Col \(position.character + 1)  ·  Read Only" }
        workspace.editor.right.text.onInspect = { [weak self] index, kind in self?.inspect(index: index, kind: kind) }
        workspace.editor.right.text.onDefinitionProbe = { [weak self] index, completion in
            guard let self else { completion(false); return }
            self.querySymbol(index: index, kind: .definition) { [weak self] value in
                guard let self, let root = self.session.reader?.root, case .locations(let locations) = value else { completion(false); return }
                completion(locations.contains { self.canNavigate($0, root: root) })
            }
        }
        workspace.editor.right.text.onSymbolClick = { [weak self] index, completion in
            guard let self else { completion([]); return }
            self.querySymbol(index: index, kind: .documentHighlight) { [weak self] value in
                guard let self, case .highlights(let occurrences) = value else { completion([]); return }
                let pane = self.workspace.editor.right
                completion(occurrences.compactMap { pane.characterRange(startLine: $0.startLine, startCharacter: $0.startCharacter, endLine: $0.endLine, endCharacter: $0.endCharacter) })
            }
        }
        workspace.editor.right.text.onHoverInvalidated = { [weak self] in
            self?.hoverRequest = UUID()
            self?.inspection.dismissHover()
        }
        workspace.editor.right.text.onHoverExited = { [weak self] in
            self?.hoverRequest = UUID()
            self?.inspection.dismissHoverWhenPointerLeaves()
        }
        workspace.editor.right.text.onHoverMoved = { [weak self] point in self?.inspection.hoverPointerMoved(to: point) }
        inspection.onHoverDismiss = { [weak self] in self?.workspace.editor.right.text.clearInspectionFeedback() }
        inspection.onFindReferences = { [weak self] index in self?.inspect(index: index, kind: "references") }
        language.onStatus = { [weak self] text in
            guard let self else { return }
            self.workspace.status.language.stringValue = text
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
        inspection.onNavigate = { [weak self] location in self?.navigate(location) }
        session.onOpen = { [weak self] state in
            guard let self else { return }
            self.workspace.editor.reset()
            self.history.record(state)
            self.displayedBranch = state.branch
            self.workspace.show(state, changesOnly: self.changesOnly)
            if let error = self.history.persistenceError { self.workspace.status.message.stringValue = error }
            self.view.window?.representedURL = state.root
            self.view.window?.title = "\(state.root.lastPathComponent) — VCode"
        }
        session.onRefresh = { [weak self] state in
            guard let self else { return }
            self.history.update(state)
            if self.displayedBranch != state.branch {
                self.resetReading()
                self.displayedBranch = state.branch
            }
            self.workspace.show(state, changesOnly: self.changesOnly)
            if let path = self.workspace.editor.activePath { self.loadFile(path, diff: self.workspace.editor.showingDiff, comparison: self.workspace.editor.activeComparison ?? .workingTree, preserveScroll: true) }
        }
        session.onError = { [weak self] error in self?.workspace.status.message.stringValue = error.localizedDescription }
        if let error = history.persistenceError {
            workspace.status.message.stringValue = error
            workspace.status.message.toolTip = error
        }
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

    func openFile(_ path: String, diff: Bool, comparison: GitComparison = .workingTree, line: Int? = nil, character: Int = 0, highlightDestination: Bool = false) {
        guard let state = session.state, !session.isSwitching else { return }
        inspectToken = UUID()
        inspection.dismiss()
        workspace.editor.prepare(path: path, diff: diff, isGit: state.isGit, comparison: comparison)
        loadFile(path, diff: workspace.editor.showingDiff, comparison: comparison, position: line.map { ($0, character) }, highlightDestination: highlightDestination)
    }

    private func loadFile(_ path: String, diff: Bool, comparison: GitComparison = .workingTree, preserveScroll: Bool = false, position: (Int, Int)? = nil, highlightDestination: Bool = false) {
        session.read(path, diff: diff, comparison: comparison) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let snapshot):
                self.workspace.editor.show(snapshot, diff: diff, preserveScroll: preserveScroll, position: position, highlightDestination: highlightDestination)
                if let reader = self.session.reader, snapshot.message == nil, self.language.supports(path), FileManager.default.fileExists(atPath: reader.root.appendingPathComponent(path).path) {
                    self.language.open(url: reader.root.appendingPathComponent(path), text: snapshot.after, root: reader.root)
                } else {
                    self.workspace.status.language.stringValue = path.hasSuffix(".py") ? "Python · Text preview" : "UTF-8"
                }
            case .failure(let error): self.workspace.editor.showError(error)
            }
        }
    }

    private func inspect(index: Int, kind: String) {
        guard let kind = InspectionKind(rawValue: kind), let root = session.reader?.root, let path = workspace.editor.activePath, language.supports(path), let position = workspace.editor.right.position(at: index) else { return }
        if kind == .hover {
            guard historyPicker == nil, picker?.isShown != true, view.window?.attachedSheet == nil else { return }
        }
        if kind == .hover { hoverRequest = UUID() } else { inspectToken = UUID() }
        let token = inspectToken
        let hoverToken = hoverRequest
        if kind == .references { workspace.status.message.stringValue = "Finding references…"; inspection.dismiss() }
        language.inspect(url: root.appendingPathComponent(path), line: position.line, character: position.character, kind: kind) { [weak self] result in
            guard let self, self.inspectToken == token, self.workspace.editor.activePath == path,
                  kind != .hover || self.hoverRequest == hoverToken else { return }
            switch result {
            case .failure(let error): if kind != .hover { self.workspace.status.message.stringValue = error.localizedDescription }
            case .success(let value):
                if kind == .references, case .locations(let locations) = value {
                    self.workspace.status.message.stringValue = "\(Set(locations).count) references"
                }
                let lines = self.workspace.editor.right.lines.filter { $0.number != nil }.map(\.text)
                self.inspection.show(value, kind: kind, index: index, textView: self.workspace.editor.right.text, root: root, currentDocument: (root.appendingPathComponent(path), lines))
            }
        }
    }

    private func querySymbol(index: Int, kind: InspectionKind, completion: @escaping (LanguageInspection?) -> Void) {
        guard historyPicker == nil, picker?.isShown != true, view.window?.attachedSheet == nil,
              !session.isSwitching, let root = session.reader?.root, let path = workspace.editor.activePath,
              language.supports(path), let position = workspace.editor.right.position(at: index) else { completion(nil); return }
        let source = workspace.editor.right.text.string
        language.inspect(url: root.appendingPathComponent(path), line: position.line, character: position.character, kind: kind) { [weak self] result in
            guard let self, self.session.reader?.root == root, self.workspace.editor.activePath == path,
                  self.workspace.editor.right.text.string == source, !self.session.isSwitching else { completion(nil); return }
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

    @objc func closeTab() { if !workspace.editor.closeActiveTab() { view.window?.performClose(nil) } }
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
        session.activate(destination) { [weak self] result in
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
        workspace.editor.reset()
        workspace.status.language.stringValue = ""
    }
    private func dismissCodeHover() {
        hoverRequest = UUID()
        workspace.editor.right.text.cancelInspection()
        inspection.dismissHover()
    }
    func shutdown() { dismissHistory(); picker?.close(); session.close(); inspection.dismiss(); language.stop() }
}
