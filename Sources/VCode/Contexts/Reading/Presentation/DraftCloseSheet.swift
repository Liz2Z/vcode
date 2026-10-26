import AppKit

/// Keep the save decision in the application's own visual language.
final class DraftCloseSheet: NSWindow {
    enum Choice { case save, discard, cancel }
    private var completion: ((Choice) -> Void)?

    init(title: String, completion: @escaping (Choice) -> Void) {
        self.completion = completion
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        self.title = "Unsaved text"
        let content = NSView()
        Theme.fill(content, Theme.background)
        contentView = content
        let heading = Theme.label("Save changes to \(title)?", size: 15)
        let detail = Theme.label("Save your text before closing this tab.", size: 12, color: Theme.muted)
        let cancel = Theme.actionButton("Cancel", target: self, action: #selector(cancelClose))
        let discard = Theme.actionButton("Don’t Save", target: self, action: #selector(discardClose))
        let save = Theme.actionButton("Save…", target: self, action: #selector(saveClose))
        save.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [discard, cancel, save])
        buttons.spacing = 8
        content.add(heading, detail, buttons)
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            detail.leadingAnchor.constraint(equalTo: heading.leadingAnchor), detail.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
            buttons.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    private func choose(_ value: Choice) {
        let callback = completion
        completion = nil
        sheetParent?.endSheet(self)
        orderOut(nil)
        callback?(value)
    }
    @objc private func saveClose() { choose(.save) }
    @objc private func discardClose() { choose(.discard) }
    @objc private func cancelClose() { choose(.cancel) }
}
