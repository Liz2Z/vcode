import AppKit

enum Theme {
    static let canvas = NSColor(hex: 0x191A1C)
    static let background = NSColor(hex: 0x202123)
    static let surface = NSColor(hex: 0x303134)
    static let floating = NSColor(hex: 0x2D2E31)
    static let text = NSColor(hex: 0xE6E6E3)
    static let muted = NSColor(hex: 0xAAA9A5)
    static let accent = NSColor(hex: 0xE6C579)
    static let green = NSColor(hex: 0x88CCA0)
    static let red = NSColor(hex: 0xE89A9E)
    static let added = NSColor(hex: 0x28362E)
    static let removed = NSColor(hex: 0x392A30)
    static let placeholder = NSColor(hex: 0x25262A)

    enum Code {
        static let fontSize: CGFloat = 12
        static let lineHeight: CGFloat = 20
        static let verticalInset: CGFloat = 12
        static func font(size: CGFloat = fontSize) -> NSFont {
            NSFont(name: "Monaco", size: size) ?? NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        static func baseline(for font: NSFont, lineHeight: CGFloat = lineHeight) -> CGFloat {
            (lineHeight + font.ascender + font.descender) / 2
        }
    }

    enum Layout {
        static let controlGap: CGFloat = 8
        static let moduleGap: CGFloat = 12
        static let inset: CGFloat = 16
        static let sectionGap: CGFloat = 24
        static let panelRadius: CGFloat = 16
        static let controlRadius: CGFloat = 8
    }

    static func label(_ string: String, size: CGFloat = 12, color: NSColor = text, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingMiddle
        return field
    }

    /// Use AppKit's small-corner rectangular bezel for both search and text inputs.
    /// Keeping the native cell preserves editing, search/cancel buttons and accessibility.
    static func searchField() -> NSSearchField { inputField(InputSearchField()) }
    static func textField() -> NSTextField { inputField(InputTextField()) }

    private static func inputField<Field: NSTextField>(_ field: Field) -> Field {
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        return field
    }

    static func button(_ symbol: String, tooltip: String, target: AnyObject?, action: Selector?) -> FeedbackButton {
        let button = FeedbackButton(frame: .zero)
        button.title = ""
        button.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = .imageOnly
        button.target = target
        button.action = action
        button.bezelStyle = .smallSquare
        button.isBordered = false
        button.contentTintColor = muted
        button.toolTip = tooltip
        button.setButtonType(.momentaryChange)
        if let cell = button.cell as? NSButtonCell {
            cell.highlightsBy = []
            cell.showsStateBy = []
            cell.imageDimsWhenDisabled = false
        }
        return button
    }

    static func actionButton(_ title: String, symbol: String? = nil, target: AnyObject? = nil, action: Selector? = nil) -> FeedbackButton {
        let button = Self.button(symbol ?? "", tooltip: title, target: target, action: action)
        button.title = title
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.font = font
        button.normalTint = text
        button.imagePosition = symbol == nil ? .noImage : .imageLeading
        button.imageHugsTitle = true
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(titleWidth) + (symbol == nil ? 20 : 40)).isActive = true
        return button
    }

    static func compactScrollers(_ scroll: NSScrollView) {
        scroll.verticalScroller?.controlSize = .small
        scroll.horizontalScroller?.controlSize = .small
    }

    static func rounded(_ view: NSView, radius: CGFloat = Layout.panelRadius, color: NSColor = background) {
        fill(view, color)
        view.layer?.cornerRadius = radius
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0
    }

    static func fill(_ view: NSView, _ color: NSColor) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }

    static func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

extension NSView {
    func add(_ children: NSView...) { children.forEach { addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false } }
}
