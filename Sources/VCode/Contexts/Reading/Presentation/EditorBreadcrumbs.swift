import AppKit

final class EditorBreadcrumbs: NSView {
    let path = Theme.label("", size: 12, color: Theme.muted)
    private let summary = Theme.label("", size: 11)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        add(path, summary)
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Layout.inset), path.centerYAnchor.constraint(equalTo: centerYAnchor), path.trailingAnchor.constraint(lessThanOrEqualTo: summary.leadingAnchor, constant: -Theme.Layout.inset),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Layout.inset), summary.centerYAnchor.constraint(equalTo: centerYAnchor), summary.widthAnchor.constraint(equalToConstant: 76)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func showCounts(_ snapshot: FileSnapshot?) {
        guard let snapshot else { summary.stringValue = ""; return }
        let counts = NSMutableAttributedString(string: "+\(snapshot.additions)", attributes: [.foregroundColor: Theme.green])
        counts.append(NSAttributedString(string: "   −\(snapshot.deletions)", attributes: [.foregroundColor: Theme.red]))
        summary.attributedStringValue = counts
    }
}
