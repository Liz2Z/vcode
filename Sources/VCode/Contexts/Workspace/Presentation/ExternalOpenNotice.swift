import AppKit

/// A centered overlay, independent of the workspace's split and reading layout.
final class ExternalOpenNotice: NSView {
    struct Failure: Equatable {
        let url: URL
        let reason: String
    }

    let surface = FloatingSurface()
    let title = Theme.label("", size: 16, weight: .semibold)
    let reason = NSTextField(wrappingLabelWithString: "")
    let paths = Theme.label("", size: 11, color: Theme.muted)
    let closeButton = Theme.button("xmark", tooltip: "Dismiss file open error", target: nil, action: nil)
    let confirmButton = Theme.actionButton("Close")
    var onDismiss: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.Layout.panelRadius
        layer?.masksToBounds = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("File open error")
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Warning")!)
        icon.contentTintColor = Theme.accent
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        reason.font = .systemFont(ofSize: 13); reason.textColor = Theme.text
        reason.maximumNumberOfLines = 3
        for label in [title, reason, paths] {
            label.alignment = .center
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for button in [closeButton, confirmButton] {
            button.target = self; button.action = #selector(dismiss)
            button.setAccessibilityLabel("Dismiss file open error")
        }
        confirmButton.normalTint = Theme.accent; confirmButton.isSelected = true
        closeButton.nextKeyView = confirmButton; confirmButton.nextKeyView = closeButton
        nextKeyView = confirmButton
        add(surface)
        surface.add(icon, title, reason, paths, closeButton, confirmButton)
        let width = surface.widthAnchor.constraint(equalToConstant: 560); width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            surface.centerXAnchor.constraint(equalTo: centerXAnchor), surface.centerYAnchor.constraint(equalTo: centerYAnchor),
            surface.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32), width,
            surface.heightAnchor.constraint(equalToConstant: 264),
            icon.centerXAnchor.constraint(equalTo: surface.centerXAnchor), icon.topAnchor.constraint(equalTo: surface.topAnchor, constant: 24),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
            title.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24), title.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 16), title.heightAnchor.constraint(equalToConstant: 20),
            reason.leadingAnchor.constraint(equalTo: title.leadingAnchor), reason.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            reason.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10), reason.heightAnchor.constraint(equalToConstant: 46),
            paths.leadingAnchor.constraint(equalTo: title.leadingAnchor), paths.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            paths.topAnchor.constraint(equalTo: reason.bottomAnchor, constant: 8), paths.heightAnchor.constraint(equalToConstant: 16),
            closeButton.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -12), closeButton.topAnchor.constraint(equalTo: surface.topAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 24), closeButton.heightAnchor.constraint(equalToConstant: 24),
            confirmButton.centerXAnchor.constraint(equalTo: surface.centerXAnchor), confirmButton.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20),
            confirmButton.widthAnchor.constraint(equalToConstant: 96), confirmButton.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ failures: [Failure], empty: Bool) {
        guard let first = failures.first else { return }
        Theme.fill(self, empty ? Theme.background : Theme.scrim)
        title.stringValue = failures.count == 1 ? "Unable to open \(first.url.lastPathComponent)" : "Unable to open \(failures.count) files"
        var reasons: [String] = []
        for failure in failures where !reasons.contains(failure.reason) { reasons.append(failure.reason) }
        reason.stringValue = reasons.joined(separator: " · ")
        paths.stringValue = failures.map { $0.url.path }.joined(separator: " · ")
        let details = failures.map { "\($0.url.path)\n\($0.reason)" }.joined(separator: "\n\n")
        for label in [title, reason, paths] { label.toolTip = details }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func keyDown(with event: NSEvent) {
        if [36, 53, 76].contains(event.keyCode) { onDismiss?() }
        else { super.keyDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        if !surface.bounds.contains(surface.convert(event.locationInWindow, from: nil)) { onDismiss?() }
    }
    @objc private func dismiss() { onDismiss?() }
}
