import AppKit

final class WelcomeView: NSView {
    let openButton = Theme.actionButton("Open Folder…", symbol: "folder")
    private let title = Theme.label("A clear view of your code.", size: 25, weight: .medium)
    private let subtitle = Theme.label("Explore your files. Understand every change.", size: 13, color: Theme.muted)
    private let hint = Theme.label("⌘O  Open folder     ⌘1  Files     ⌘2  Changes", size: 11, color: Theme.muted)
    private var hintAfterButton: NSLayoutConstraint!
    private var hintAfterSubtitle: NSLayoutConstraint!
    private var workspaceOpen = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let mark = NSImageView(image: NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "VCode") ?? NSImage())
        mark.contentTintColor = Theme.accent
        let iconContent = NSView()
        iconContent.add(mark)
        openButton.isSelected = true
        add(iconContent, title, subtitle, openButton, hint)
        hintAfterButton = hint.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: Theme.Layout.sectionGap)
        hintAfterSubtitle = hint.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: Theme.Layout.sectionGap)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor), title.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -8),
            iconContent.centerXAnchor.constraint(equalTo: centerXAnchor), iconContent.bottomAnchor.constraint(equalTo: title.topAnchor, constant: -Theme.Layout.sectionGap), iconContent.widthAnchor.constraint(equalToConstant: 64), iconContent.heightAnchor.constraint(equalToConstant: 64),
            mark.centerXAnchor.constraint(equalTo: iconContent.centerXAnchor), mark.centerYAnchor.constraint(equalTo: iconContent.centerYAnchor), mark.widthAnchor.constraint(equalToConstant: 40), mark.heightAnchor.constraint(equalToConstant: 34),
            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            openButton.centerXAnchor.constraint(equalTo: centerXAnchor), openButton.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: Theme.Layout.sectionGap), openButton.widthAnchor.constraint(equalToConstant: 154), openButton.heightAnchor.constraint(equalToConstant: 36),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor), hintAfterButton
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(hasWorkspace: Bool) {
        guard workspaceOpen != hasWorkspace else { return }
        workspaceOpen = hasWorkspace
        openButton.isHidden = hasWorkspace
        openButton.isEnabled = !hasWorkspace
        title.stringValue = hasWorkspace ? "Select a file to begin." : "A clear view of your code."
        subtitle.stringValue = hasWorkspace ? "Browse Files or review Changes in the sidebar." : "Explore your files. Understand every change."
        hint.stringValue = hasWorkspace ? "⌘1  Files     ⌘2  Changes" : "⌘O  Open folder     ⌘1  Files     ⌘2  Changes"
        NSLayoutConstraint.deactivate([hintAfterButton, hintAfterSubtitle])
        (hasWorkspace ? hintAfterSubtitle : hintAfterButton)?.isActive = true
    }
}
