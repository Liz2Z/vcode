import AppKit
import Sparkle

// Sparkle owns version comparison, scheduling, signature verification and installation.
// Its internal preferences are the user-approved exception to XDG persistence.
final class UpdateController: NSObject, NSMenuItemValidation, SPUUpdaterDelegate {
    var onError: ((String) -> Void)?
    var beforeInstall: (() -> Void)?
    private(set) var updater: SPUUpdater?
    private let bundle: Bundle
    private var checkItem: NSMenuItem?
    private var automaticItem: NSMenuItem?
    private var settings: SPUUpdaterSettings?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        super.init()
    }

    func addMenuItems(to menu: NSMenu) {
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        checkItem = check
        let automatic = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutomaticChecks), keyEquivalent: "")
        automatic.target = self
        menu.addItem(automatic)
        automaticItem = automatic
        updateMenu()
    }

    func start() {
        guard updater == nil else { return }
        guard bundle.bundleURL.pathExtension == "app",
              let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed),
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")),
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else {
            onError?("Updates are available in the packaged VCode app.")
            return
        }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let candidate = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: self)
        do {
            try candidate.start()
            updater = candidate
            settings = SPUUpdaterSettings(hostBundle: bundle)
            updateMenu()
            // Check at launch as well as Sparkle's scheduled hourly checks.
            if settings?.automaticallyChecksForUpdates == true { candidate.checkForUpdatesInBackground() }
        } catch {
            onError?("Could not start update checks: " + error.localizedDescription)
        }
    }

    @objc private func checkForUpdates() { updater?.checkForUpdates() }

    @objc private func toggleAutomaticChecks() {
        guard let settings else { return }
        settings.automaticallyChecksForUpdates.toggle()
        updateMenu()
    }

    private func updateMenu() {
        checkItem?.isEnabled = updater?.canCheckForUpdates == true
        automaticItem?.isEnabled = settings != nil
        automaticItem?.state = settings?.automaticallyChecksForUpdates == true ? .on : .off
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        updateMenu()
        if menuItem === checkItem { return updater?.canCheckForUpdates == true }
        return settings != nil
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) { beforeInstall?() }
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) { beforeInstall?() }
}
