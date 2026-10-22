import AppKit

final class EditorBreadcrumbs: NSView {
    let path = Theme.label("", size: 12, color: Theme.muted)
    private let summary = Theme.label("", size: 11)
    let sourceButton = Theme.actionButton("Source")
    let previewButton = Theme.actionButton("Preview")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let controls = NSStackView(views: [summary, sourceButton, previewButton])
        controls.orientation = .horizontal
        controls.spacing = 4
        controls.alignment = .centerY
        for button in [sourceButton, previewButton] {
            button.feedbackRadius = 4
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }
        sourceButton.setAccessibilityLabel("Markdown source")
        previewButton.setAccessibilityLabel("Markdown preview")
        add(path, controls)
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), path.centerYAnchor.constraint(equalTo: centerYAnchor), path.trailingAnchor.constraint(lessThanOrEqualTo: controls.leadingAnchor, constant: -Theme.Layout.inset),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), controls.centerYAnchor.constraint(equalTo: centerYAnchor), summary.widthAnchor.constraint(equalToConstant: 76)
        ])
        showMarkdownControls(false, preview: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    func showMarkdownControls(_ visible: Bool, preview: Bool) {
        sourceButton.isHidden = !visible
        previewButton.isHidden = !visible
        summary.isHidden = visible
        sourceButton.isSelected = !preview
        previewButton.isSelected = preview
    }

    func showCounts(_ snapshot: FileSnapshot?) {
        guard let snapshot else { summary.stringValue = ""; return }
        let counts = NSMutableAttributedString(string: "+\(snapshot.additions)", attributes: [.foregroundColor: Theme.green])
        counts.append(NSAttributedString(string: "   −\(snapshot.deletions)", attributes: [.foregroundColor: Theme.red]))
        summary.attributedStringValue = counts
    }
}
