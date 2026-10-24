import AppKit

enum Theme {
    // AppKit resolves these colors per appearance, including attributed source text.
    static func color(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in NSColor(hex: isDark(appearance) ? dark : light) }
    }
    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    static let canvas = color(light: 0xECEDEB, dark: 0x191A1C)
    static let background = color(light: 0xFAFAF8, dark: 0x202123)
    static let surface = color(light: 0xE4E5E1, dark: 0x303134)
    static let floating = color(light: 0xFFFFFF, dark: 0x2D2E31)
    static let text = color(light: 0x292C30, dark: 0xE6E6E3)
    static let muted = color(light: 0x646966, dark: 0xAAA9A5)
    static let accent = color(light: 0x9A5B16, dark: 0xE6C579)
    static let green = color(light: 0x2C7046, dark: 0x88CCA0)
    static let red = color(light: 0xAA3541, dark: 0xE89A9E)
    enum GitStatus {
        static let modified = color(light: 0x9D4500, dark: 0xFFBE3B)
        static let added = color(light: 0x006F2D, dark: 0x50D982)
        static let deleted = color(light: 0xB91F35, dark: 0xFF6978)
    }
    static let added = color(light: 0xEAF3E6, dark: 0x28362E)
    static let removed = color(light: 0xFAE8E8, dark: 0x392A30)
    static let placeholder = color(light: 0xF0F0ED, dark: 0x25262A)
    static let hover = overlay(light: 0.065, dark: 0.09)
    static let selectedHover = overlay(light: 0.10, dark: 0.14)
    static let hoveredTab = color(light: 0xD9DAD6, dark: 0x494A4C)
    static let shadow = NSColor(name: nil) { appearance in NSColor.black.withAlphaComponent(isDark(appearance) ? 0.4 : 0.15) }
    static let scrim = NSColor(name: nil) { appearance in NSColor.black.withAlphaComponent(isDark(appearance) ? 0.22 : 0.12) }

    private static func overlay(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? NSColor.white.withAlphaComponent(dark) : NSColor.black.withAlphaComponent(light)
        }
    }

    // CALayer keeps a resolved CGColor, so retain its semantic source weakly by
    // layer and resolve it again when the application's appearance changes.
    enum LayerColor { case background, border, shadow }
    private final class LayerColors: NSObject { var values: [LayerColor: NSColor] = [:] }
    private static let layerColors = NSMapTable<CALayer, LayerColors>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    static func setLayerColor(_ color: NSColor, on layer: CALayer?, property: LayerColor = .background) {
        guard let layer else { return }
        let colors = layerColors.object(forKey: layer) ?? LayerColors()
        colors.values[property] = color
        layerColors.setObject(colors, forKey: layer)
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance { apply(color.cgColor, to: layer, property: property) }
    }

    static func refreshLayerColors(using appearance: NSAppearance) {
        appearance.performAsCurrentDrawingAppearance {
            for case let layer as CALayer in layerColors.keyEnumerator().allObjects {
                for (property, color) in layerColors.object(forKey: layer)?.values ?? [:] {
                    apply(color.cgColor, to: layer, property: property)
                }
            }
        }
    }

    private static func apply(_ color: CGColor, to layer: CALayer, property: LayerColor) {
        switch property {
        case .background: layer.backgroundColor = color
        case .border: layer.borderColor = color
        case .shadow: layer.shadowColor = color
        }
    }

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
        setLayerColor(color, on: view.layer)
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
