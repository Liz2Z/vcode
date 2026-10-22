import AppKit

final class GlassSurface: NSView {
    let content: NSView
    let material: NSView

    init(content: NSView = NSView(), radius: CGFloat = Theme.Layout.panelRadius) {
        self.content = content
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.tintColor = Theme.surface.withAlphaComponent(0.55)
            glass.cornerRadius = radius
            glass.contentView = content
            material = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .sidebar
            blur.blendingMode = .withinWindow
            blur.state = .followsWindowActiveState
            blur.wantsLayer = true
            blur.layer?.cornerRadius = radius
            blur.layer?.masksToBounds = true
            blur.addSubview(content)
            material = blur
        }
        super.init(frame: .zero)
        addSubview(material)
        Theme.pin(material, to: self)
        Theme.pin(content, to: material)
    }

    required init?(coder: NSCoder) { fatalError() }
}
