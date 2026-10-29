import AppKit

/// Runtime icons use AppKit's Dock icon API; the signed application bundle stays intact.
final class AppIconController: NSObject {
    let settings: AppIconSettings
    let defaultStyle: AppIconStyle
    private(set) var currentStyle: AppIconStyle
    private(set) var currentImage: NSImage?
    var onError: ((String) -> Void)?
    private let resourceDirectory: URL?
    private let applyIcon: (NSImage) -> Void
    private var items: [NSMenuItem] = []
    private var resetItem: NSMenuItem?

    init(settings: AppIconSettings = AppIconSettings(), resourceDirectory: URL? = Bundle.main.resourceURL,
         defaultStyle: AppIconStyle = AppIconStyle(rawValue: Bundle.main.object(forInfoDictionaryKey: "VCodeDefaultAppIcon") as? String ?? "") ?? .origami,
         applyIcon: @escaping (NSImage) -> Void = { NSApp.applicationIconImage = $0 }) {
        self.settings = settings
        self.resourceDirectory = resourceDirectory
        self.defaultStyle = defaultStyle
        self.currentStyle = defaultStyle
        self.applyIcon = applyIcon
        super.init()
    }

    func start() {
        let requested = settings.selection ?? defaultStyle
        if let image = image(for: requested) {
            apply(image, style: requested)
        } else {
            if let fallback = image(for: defaultStyle) { apply(fallback, style: defaultStyle) }
            onError?("Could not load the \(requested.title) app icon. Using the build default.")
        }
        if let error = settings.persistenceError { onError?(error) }
    }

    func addMenu(to parent: NSMenu) {
        let item = NSMenuItem(title: "App Icon", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: item.title)
        menu.autoenablesItems = false
        item.submenu = menu
        parent.addItem(item)
        for style in AppIconStyle.allCases {
            let option = NSMenuItem(title: style.title, action: #selector(selectIcon(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = style.rawValue
            if let thumbnail = image(for: style) {
                thumbnail.size = NSSize(width: 24, height: 24)
                option.image = thumbnail
            } else {
                option.isEnabled = false
                option.toolTip = "App icon artwork is unavailable."
            }
            menu.addItem(option)
            items.append(option)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Use Build Default", action: #selector(resetIcon), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        resetItem = reset
        updateChecks()
    }

    @objc func selectIcon(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = AppIconStyle(rawValue: raw) else { return }
        select(style)
    }

    @objc private func resetIcon() { select(nil) }

    func select(_ style: AppIconStyle?) {
        let resolved = style ?? defaultStyle
        guard let image = image(for: resolved) else {
            onError?("Could not load the \(resolved.title) app icon. Your current icon has been kept.")
            return
        }
        do {
            try settings.save(style)
            apply(image, style: resolved)
        } catch {
            onError?("Could not save app icon settings: " + error.localizedDescription)
        }
    }

    private func image(for style: AppIconStyle) -> NSImage? {
        let path = style == defaultStyle ? "AppIcon.icns" : "AppIcons/\(style.rawValue).png"
        guard let url = resourceDirectory?.appendingPathComponent(path),
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }

    private func apply(_ image: NSImage, style: AppIconStyle) {
        currentImage = image
        currentStyle = style
        applyIcon(image)
        updateChecks()
    }

    private func updateChecks() {
        for item in items { item.state = item.representedObject as? String == currentStyle.rawValue ? .on : .off }
        resetItem?.isEnabled = settings.selection != nil && image(for: defaultStyle) != nil
    }
}
