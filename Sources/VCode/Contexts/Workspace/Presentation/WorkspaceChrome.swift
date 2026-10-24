import AppKit

final class WorkspaceHeader: NSView {
    let branchButton = Theme.actionButton("—", symbol: "arrow.triangle.branch")
    let worktreeButton = Theme.actionButton("—", symbol: "folder")
    let openButton = Theme.actionButton("Open Folder", symbol: "folder.badge.plus")
    private var isGit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        openButton.toolTip = "Open Folder (⌘O)"
        branchButton.setAccessibilityLabel("Branch")
        worktreeButton.setAccessibilityLabel("Worktree")
        worktreeButton.title = "VCode"
        worktreeButton.font = .systemFont(ofSize: 14, weight: .semibold)
        worktreeButton.disabledTint = Theme.text
        worktreeButton.toolTip = "Open a folder to begin"
        for button in [branchButton, worktreeButton] {
            button.horizontalPadding = Theme.Layout.moduleGap
            button.isEnabled = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        worktreeButton.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(252), for: .horizontal)
        add(worktreeButton, branchButton, openButton)
        NSLayoutConstraint.activate([
            worktreeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 96), worktreeButton.centerYAnchor.constraint(equalTo: centerYAnchor), worktreeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 320), worktreeButton.heightAnchor.constraint(equalToConstant: 32),
            branchButton.leadingAnchor.constraint(equalTo: worktreeButton.trailingAnchor, constant: 8), branchButton.centerYAnchor.constraint(equalTo: centerYAnchor), branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200), branchButton.heightAnchor.constraint(equalToConstant: 32), branchButton.trailingAnchor.constraint(lessThanOrEqualTo: openButton.leadingAnchor, constant: -16),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), openButton.centerYAnchor.constraint(equalTo: centerYAnchor), openButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: WorkspaceState) {
        isGit = state.isGit
        branchButton.title = state.isGit ? state.branch : "—"
        worktreeButton.title = state.root.lastPathComponent
        branchButton.toolTip = state.isGit ? "Switch local branch · " + state.branch : "Open a Git repository to switch branches"
        worktreeButton.toolTip = (state.isGit ? "Switch worktree · " : "Current folder · ") + state.root.path
        worktreeButton.setAccessibilityLabel(state.isGit ? "Worktree" : "Current folder")
        setBusy(false)
    }
    func setBusy(_ busy: Bool) {
        branchButton.isEnabled = isGit && !busy
        worktreeButton.isEnabled = isGit && !busy
        openButton.isEnabled = !busy
    }
}

final class WorkspaceNavigation: NSView {
    let files = Theme.actionButton("Files")
    let changes = Theme.actionButton("Changes")
    let search = Theme.actionButton("Search")
    let changesIndicator = NSView()
    private var changeCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        files.toolTip = "All files (⌘1)"
        changes.toolTip = "Changes (⌘2)"
        search.toolTip = "Search in project (⌘⇧F)"
        search.isEnabled = false
        // Keep full titles at 220 points; equal widths yield to title minima.
        for button in [files, changes, search] { button.horizontalPadding = 8 }
        add(files, changes, search)
        changesIndicator.setAccessibilityElement(false)
        changesIndicator.wantsLayer = true
        if let layer = changesIndicator.layer {
            Theme.setLayerColor(Theme.accent, on: layer)
            layer.cornerRadius = 2.5
            Theme.setLayerColor(Theme.accent, on: layer, property: .shadow)
            layer.shadowOpacity = 0.9
            layer.shadowRadius = 3.5
            layer.shadowOffset = .zero
        }
        changes.add(changesIndicator)
        let equalWidths = [files.widthAnchor.constraint(equalTo: changes.widthAnchor), files.widthAnchor.constraint(equalTo: search.widthAnchor)]
        equalWidths.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate([
            files.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.controlGap), files.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Layout.controlGap), files.bottomAnchor.constraint(equalTo: bottomAnchor),
            changes.leadingAnchor.constraint(equalTo: files.trailingAnchor, constant: 4), changes.topAnchor.constraint(equalTo: files.topAnchor), changes.bottomAnchor.constraint(equalTo: files.bottomAnchor),
            search.leadingAnchor.constraint(equalTo: changes.trailingAnchor, constant: 4), search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.controlGap), search.topAnchor.constraint(equalTo: files.topAnchor), search.bottomAnchor.constraint(equalTo: files.bottomAnchor),
            changesIndicator.widthAnchor.constraint(equalToConstant: 5), changesIndicator.heightAnchor.constraint(equalToConstant: 5),
            changesIndicator.topAnchor.constraint(equalTo: changes.topAnchor, constant: 3), changesIndicator.trailingAnchor.constraint(equalTo: changes.trailingAnchor, constant: -4)
        ] + equalWidths)
        select(changes: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(changes selected: Bool?) {
        for (button, active) in [(files, selected == false), (changes, selected == true), (search, selected == nil)] {
            button.isSelected = active
            button.setAccessibilityValue(active ? 1 : 0)
        }
        updateIndicator()
    }

    func updateChanges(count: Int) {
        changeCount = count
        changes.toolTip = "Changes (⌘2) · \(count) files"
        changes.setAccessibilityHelp(count > 0 ? "\(count) Git changes" : "No Git changes")
        updateIndicator()
    }

    private func updateIndicator() {
        changesIndicator.isHidden = changeCount == 0 || changes.isSelected
    }
}

final class WorkspaceStatus: NSView {
    let message = Theme.label("Open a folder to begin", size: 11, color: Theme.muted)
    let language = Theme.label("", size: 11, color: Theme.muted)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock", accessibilityDescription: "Read only") ?? NSImage())
        icon.contentTintColor = Theme.muted
        add(icon, message, language)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), icon.widthAnchor.constraint(equalToConstant: 10), icon.heightAnchor.constraint(equalToConstant: 10), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.Layout.controlGap), message.centerYAnchor.constraint(equalTo: centerYAnchor),
            language.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), language.centerYAnchor.constraint(equalTo: centerYAnchor), language.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: Theme.Layout.inset)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
