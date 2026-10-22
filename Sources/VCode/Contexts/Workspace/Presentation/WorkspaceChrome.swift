import AppKit

final class WorkspaceHeader: NSView {
    let project = Theme.label("VCode", size: 14, weight: .semibold)
    let branchButton = Theme.actionButton("Branch", symbol: "arrow.triangle.branch")
    let worktreeButton = Theme.actionButton("Worktree", symbol: "folder")
    let openButton = Theme.actionButton("Open Folder", symbol: "folder.badge.plus")
    let historyButton = Theme.actionButton("Recent", symbol: "clock.arrow.circlepath")
    let refreshButton = Theme.actionButton("Refresh", symbol: "arrow.clockwise")
    private var isGit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refreshButton.toolTip = "Refresh (⌘R)"
        openButton.toolTip = "Open Folder (⌘O)"
        historyButton.toolTip = "Recently opened projects and worktrees"
        project.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [branchButton, worktreeButton] {
            button.horizontalPadding = Theme.Layout.moduleGap
            button.isEnabled = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        }
        add(project, branchButton, worktreeButton, historyButton, openButton, refreshButton)
        NSLayoutConstraint.activate([
            project.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 96), project.centerYAnchor.constraint(equalTo: centerYAnchor), project.widthAnchor.constraint(lessThanOrEqualToConstant: 240), project.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),
            branchButton.leadingAnchor.constraint(equalTo: project.trailingAnchor, constant: 16), branchButton.centerYAnchor.constraint(equalTo: centerYAnchor), branchButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200), branchButton.heightAnchor.constraint(equalToConstant: 32),
            worktreeButton.leadingAnchor.constraint(equalTo: branchButton.trailingAnchor, constant: 8), worktreeButton.centerYAnchor.constraint(equalTo: centerYAnchor), worktreeButton.widthAnchor.constraint(lessThanOrEqualToConstant: 200), worktreeButton.heightAnchor.constraint(equalToConstant: 32), worktreeButton.trailingAnchor.constraint(lessThanOrEqualTo: historyButton.leadingAnchor, constant: -16),
            historyButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8), historyButton.centerYAnchor.constraint(equalTo: centerYAnchor), historyButton.heightAnchor.constraint(equalToConstant: 32),
            refreshButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), refreshButton.centerYAnchor.constraint(equalTo: centerYAnchor), refreshButton.heightAnchor.constraint(equalToConstant: 32),
            openButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8), openButton.centerYAnchor.constraint(equalTo: centerYAnchor), openButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ state: WorkspaceState) {
        isGit = state.isGit
        project.stringValue = state.root.lastPathComponent
        branchButton.title = state.isGit ? "Branch · " + state.branch : "Branch"
        worktreeButton.title = "Worktree · " + state.root.lastPathComponent
        branchButton.toolTip = state.isGit ? "Switch local branch · " + state.branch : "Open a Git repository to switch branches"
        worktreeButton.toolTip = "Switch worktree · " + state.root.path
        setBusy(false)
    }
    func setBusy(_ busy: Bool) {
        branchButton.isEnabled = isGit && !busy
        worktreeButton.isEnabled = isGit && !busy
        openButton.isEnabled = !busy
        refreshButton.isEnabled = !busy
        historyButton.isEnabled = !busy
    }
}

final class WorkspaceNavigation: NSView {
    let files = Theme.actionButton("Files", symbol: "doc.on.doc")
    let changes = Theme.actionButton("Changes", symbol: "arrow.triangle.branch")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        files.toolTip = "All files (⌘1)"
        changes.toolTip = "Changes (⌘2)"
        add(files, changes)
        NSLayoutConstraint.activate([
            files.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.controlGap), files.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Layout.controlGap), files.bottomAnchor.constraint(equalTo: bottomAnchor),
            changes.leadingAnchor.constraint(equalTo: files.trailingAnchor, constant: 4), changes.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.controlGap), changes.topAnchor.constraint(equalTo: files.topAnchor), changes.bottomAnchor.constraint(equalTo: files.bottomAnchor),
            files.widthAnchor.constraint(equalTo: changes.widthAnchor)
        ])
        select(changes: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func select(changes selected: Bool) {
        for (button, active) in [(files, !selected), (changes, selected)] {
            button.isSelected = active
            button.setAccessibilityValue(active ? 1 : 0)
        }
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
