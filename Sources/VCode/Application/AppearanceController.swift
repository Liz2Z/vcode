import AppKit

final class AppearanceController: NSObject {
    let settings: AppearanceSettings
    var onError: ((String) -> Void)?
    private var observation: NSKeyValueObservation?
    private var items: [NSMenuItem] = []

    init(settings: AppearanceSettings = AppearanceSettings()) {
        self.settings = settings
        super.init()
    }

    func start() {
        apply()
        observation = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in self?.refresh() }
    }

    func addMenuItems(to menu: NSMenu) {
        for mode in AppearanceMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = mode.rawValue
            menu.addItem(item); items.append(item)
        }
        updateChecks()
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = AppearanceMode(rawValue: raw) else { return }
        select(mode)
    }

    func select(_ mode: AppearanceMode) {
        settings.save(mode)
        apply()
        if let error = settings.persistenceError { onError?(error) }
    }

    private func apply() {
        switch settings.mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
        updateChecks()
        refresh()
    }
    private func updateChecks() {
        for item in items { item.state = item.representedObject as? String == settings.mode.rawValue ? .on : .off }
    }
    private func refresh() {
        Theme.refreshLayerColors(using: NSApp.effectiveAppearance)
        // Repaint existing attributed text, never reload a document or rebuild
        // its layout/session just to change the palette.
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            if let text = view as? NSTextView {
                text.layoutManager?.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: text.string.utf16.count))
            }
            view.subviews.forEach(invalidate)
        }
        for window in NSApp.windows {
            if let content = window.contentView { invalidate(content) }
            window.invalidateShadow()
        }
    }
}
