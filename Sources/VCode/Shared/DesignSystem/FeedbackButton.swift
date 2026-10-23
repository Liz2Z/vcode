import AppKit

final class FeedbackButton: NSButton {
    var isSelected = false { didSet { updateFeedback() } }
    var normalTint = Theme.muted { didSet { updateFeedback() } }
    var disabledTint: NSColor? { didSet { updateFeedback() } }
    var feedbackRadius: CGFloat = Theme.Layout.controlRadius { didSet { updateFeedback() } }
    var horizontalPadding: CGFloat = 10 {
        didSet {
            updateContent()
            invalidateIntrinsicContentSize()
        }
    }
    private let icon = NSImageView()
    private let label = ButtonTitleField(labelWithString: "")
    private let content = NSStackView()
    private var leadingInset: NSLayoutConstraint!
    private var trailingInset: NSLayoutConstraint!
    private var contentReady = false
    private static let iconSize: CGFloat = 14
    private static let iconGap: CGFloat = 6
    private var hovered = false
    private var pressed = false
    private var focused = false
    private var tracking: NSTrackingArea?

    override var isEnabled: Bool { didSet { updateFeedback() } }
    override var title: String { didSet { updateContent() } }
    override var image: NSImage? { didSet { updateContent() } }
    override var font: NSFont? { didSet { updateContent() } }
    override var imagePosition: NSControl.ImagePosition { didSet { updateContent() } }
    // Feedback fills the view bounds, so constraints must describe those bounds too.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureContent()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureContent()
    }

    private func configureContent() {
        focusRingType = .none
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        icon.imageScaling = .scaleProportionallyDown
        icon.imageAlignment = .alignCenter
        icon.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Self.iconGap
        content.setContentHuggingPriority(.required, for: .horizontal)
        content.addArrangedSubview(icon)
        content.addArrangedSubview(label)
        add(content)
        leadingInset = content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor)
        trailingInset = content.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            content.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingInset, trailingInset
        ])
        contentReady = true
        updateContent()
        updateFeedback()
    }

    private func updateContent() {
        guard contentReady else { return }
        icon.image = image
        icon.isHidden = image == nil || imagePosition == .noImage
        label.stringValue = title
        label.font = font ?? .systemFont(ofSize: 12, weight: .medium)
        label.isHidden = title.isEmpty || imagePosition == .imageOnly
        let inset = label.isHidden ? 0 : horizontalPadding
        leadingInset.constant = inset
        trailingInset.constant = -inset
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        guard contentReady else { return super.intrinsicContentSize }
        let iconWidth = icon.isHidden ? 0 : Self.iconSize
        let textSize = label.isHidden ? NSSize.zero : label.intrinsicContentSize
        let gap = icon.isHidden || label.isHidden ? 0 : Self.iconGap
        let inset = label.isHidden ? 0 : horizontalPadding * 2
        return NSSize(width: max(24, ceil(iconWidth + gap + textSize.width + inset)), height: max(24, ceil(max(iconWidth, textSize.height) + 12)))
    }

    // Child views own content rendering; the native cell only handles button
    // actions and accessibility. Never draw a second image/title via the cell.
    override func draw(_ dirtyRect: NSRect) {}

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focused = true; updateFeedback() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focused = false; updateFeedback() }
        return accepted
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
        refreshHover()
    }

    func refreshHover() {
        hovered = containsVisibleWindowMouse
        updateFeedback()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        updateFeedback()
        defer { pressed = false; updateFeedback() }
        super.mouseDown(with: event)
    }

    private func updateFeedback() {
        wantsLayer = true
        layer?.cornerRadius = feedbackRadius
        let fill: NSColor
        if !isEnabled { fill = .clear }
        else if pressed { fill = Theme.accent.withAlphaComponent(0.24) }
        else if hovered { fill = NSColor.white.withAlphaComponent(isSelected ? 0.14 : 0.1) }
        else if isSelected { fill = Theme.accent.withAlphaComponent(0.18) }
        else { fill = .clear }
        layer?.backgroundColor = fill.cgColor
        layer?.borderWidth = focused && isEnabled ? 1 : 0
        layer?.borderColor = Theme.accent.cgColor
        contentTintColor = !isEnabled ? (disabledTint ?? Theme.muted.withAlphaComponent(0.7)) : (pressed || isSelected ? Theme.accent : hovered ? Theme.text : normalTint)
        icon.contentTintColor = contentTintColor
        label.textColor = contentTintColor
        needsDisplay = true
    }
}

private final class ButtonTitleField: NSTextField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
}

extension NSView {
    // A scrolled-out view can lose its tracking area without receiving an exit.
    // Reconcile against the current pointer and clipped geometry instead of
    // relying on the last tracking event's boolean state.
    var containsVisibleWindowMouse: Bool {
        guard let window, window.isKeyWindow, !isHiddenOrHasHiddenAncestor else { return false }
        return visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
