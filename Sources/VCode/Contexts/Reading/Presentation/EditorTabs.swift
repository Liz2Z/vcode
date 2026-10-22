import AppKit

final class EditorTabs: NSView {
    var onSelect: ((ReadingDocument) -> Void)?
    var onClose: ((ReadingDocument) -> Void)?
    private var documents: [ReadingDocument] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.alignment = .height
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 32).isActive = true
        scroll.documentView = stack
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        add(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.controlGap), scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.controlGap), scroll.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Layout.controlGap), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ session: ReaderSession) {
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        var activeTab: NSView?
        documents = session.documents
        for document in documents {
            let path = document.path
            let active = document == session.activeDocument
            let content = TabContent(active: active)
            let title = TabTitleButton(frame: .zero)
            title.onPress = { [weak content] pressed in content?.setPressed(pressed) }
            title.title = (path as NSString).lastPathComponent + (document.comparison == .staged ? " · Staged" : document.comparison == .unstaged ? " · Unstaged" : "")
            title.target = self; title.action = #selector(selectTab(_:))
            title.identifier = NSUserInterfaceItemIdentifier(document.id)
            title.bezelStyle = .smallSquare
            title.isBordered = false
            title.setButtonType(.momentaryChange)
            title.focusRingType = .none
            if let cell = title.cell as? NSButtonCell {
                cell.highlightsBy = []
                cell.showsStateBy = []
                cell.lineBreakMode = .byTruncatingMiddle
            }
            title.alignment = .left
            title.font = .systemFont(ofSize: 13, weight: active ? .medium : .regular)
            title.contentTintColor = active ? Theme.accent : Theme.muted
            title.setAccessibilityValue(active ? 1 : 0)
            title.image = NSImage(systemSymbolName: ["ts", "tsx"].contains((path as NSString).pathExtension) ? "curlybraces" : "doc.text", accessibilityDescription: nil)
            title.imagePosition = .imageLeading
            title.imageHugsTitle = true
            title.toolTip = path + (document.comparison.map { " · " + $0.rawValue } ?? " · Source")
            let close = Theme.button("xmark", tooltip: "Close tab", target: self, action: #selector(closeTab(_:)))
            close.feedbackRadius = 4
            close.identifier = NSUserInterfaceItemIdentifier(document.id)
            content.add(title, close)
            NSLayoutConstraint.activate([
                content.heightAnchor.constraint(equalToConstant: 32), content.widthAnchor.constraint(greaterThanOrEqualToConstant: 145), content.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
                title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), title.centerYAnchor.constraint(equalTo: content.centerYAnchor), title.heightAnchor.constraint(equalToConstant: 28), title.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -8),
                close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4), close.centerYAnchor.constraint(equalTo: content.centerYAnchor), close.widthAnchor.constraint(equalToConstant: 24), close.heightAnchor.constraint(equalToConstant: 24)
            ])
            stack.addArrangedSubview(content)
            if active { activeTab = content }
        }
        stack.layoutSubtreeIfNeeded()
        stack.frame.size.width = max(stack.fittingSize.width, scroll.bounds.width)
        if let activeTab { stack.scrollToVisible(activeTab.frame.insetBy(dx: -8, dy: 0)) }
    }

    @objc private func selectTab(_ button: NSButton) { if let document = documents.first(where: { $0.id == button.identifier?.rawValue }) { onSelect?(document) } }
    @objc private func closeTab(_ button: NSButton) { if let document = documents.first(where: { $0.id == button.identifier?.rawValue }) { onClose?(document) } }
}

private final class TabContent: NSView {
    private var tracking: NSTrackingArea?
    private let active: Bool
    private var hovered = false
    private var pressed = false

    init(active: Bool) {
        self.active = active
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.controlRadius
        updateFeedback()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateFeedback()
    }

    override func mouseExited(with event: NSEvent) { hovered = false; updateFeedback() }
    func setPressed(_ value: Bool) { pressed = value; updateFeedback() }
    private func updateFeedback() {
        let color: NSColor = pressed ? Theme.accent.withAlphaComponent(0.24) : active ? (hovered ? Theme.surface.blended(withFraction: 0.12, of: .white)! : Theme.surface) : hovered ? NSColor.white.withAlphaComponent(0.08) : .clear
        layer?.backgroundColor = color.cgColor
    }
}

private final class TabTitleButton: NSButton {
    var onPress: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        defer { onPress?(false) }
        super.mouseDown(with: event)
    }
}
