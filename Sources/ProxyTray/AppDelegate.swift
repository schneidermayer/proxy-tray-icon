import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var statusMenuItem: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private lazy var appVersion = resolveAppVersion()
    private lazy var statusItemTooltip = makeStatusItemTooltip()
    private let controller = ProxyController()

    static func main() {
        if KeyPassphraseVault.answerAskPassIfRequested() {
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        controller.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.refreshUI(state: state) }
        }
        controller.bootstrap()
        refreshUI(state: controller.state)
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()

        statusMenuItem = NSMenuItem(title: makeStatusMenuTitle(active: false), action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "Enable Proxy", action: #selector(toggleProxy), keyEquivalent: "p")
        menu.addItem(toggleMenuItem)
        menu.addItem(NSMenuItem.separator())

        let routeAllItem = NSMenuItem(title: "Route All Traffic", action: #selector(toggleRouteAll), keyEquivalent: "")
        routeAllItem.state = controller.state.routeAll ? .on : .off
        menu.addItem(routeAllItem)

        menu.addItem(withTitle: "Open Whitelist File", action: #selector(openWhitelist), keyEquivalent: "")
        menu.addItem(withTitle: "Update SSH Settings", action: #selector(updateSshSettings), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Restart Proxy", action: #selector(restartProxy), keyEquivalent: "r")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.image = IconFactory.icon(active: false)
        statusItem.button?.imagePosition = .imageLeading
    }

    @objc private func toggleProxy() {
        if controller.state.proxyActive {
            controller.disableProxy()
        } else {
            controller.enableProxy()
        }
    }
    @objc private func toggleRouteAll() { controller.toggleRouteAll() }
    @objc private func openWhitelist() { controller.openWhitelist() }
    @objc private func updateSshSettings() { controller.promptForSshSettings() }
    @objc private func restartProxy() { controller.restartProxy() }
    @objc private func quit() { controller.cleanup(); NSApp.terminate(nil) }

    private func refreshUI(state: ProxyState) {
        statusItem.button?.image = IconFactory.icon(active: state.proxyActive)
        statusItem.button?.toolTip = statusItemTooltip
        statusMenuItem.title = makeStatusMenuTitle(active: state.proxyActive)
        toggleMenuItem.title = state.proxyActive ? "Disable Proxy" : "Enable Proxy"
        toggleMenuItem.isEnabled = true
        if let routeAllItem = menu.items.first(where: { $0.action == #selector(toggleRouteAll) }) {
            routeAllItem.state = state.routeAll ? .on : .off
            routeAllItem.title = state.routeAll ? "Route All Traffic (on)" : "Route All Traffic"
        }
        if let restartItem = menu.items.first(where: { $0.action == #selector(restartProxy) }) {
            restartItem.isEnabled = state.proxyActive
        }
    }

    private func makeStatusItemTooltip() -> String {
        guard let version = appVersion else { return "ProxyTray" }
        return "ProxyTray \(version)"
    }

    private func makeStatusMenuTitle(active: Bool) -> String {
        let status = active ? "Active" : "Inactive"
        guard let version = appVersion else { return "Status: \(status)" }
        return "\(version) – Status: \(status)"
    }

    private func resolveAppVersion() -> String? {
        if let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let trimmedVersion = bundleVersion.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedVersion.isEmpty {
                return trimmedVersion
            }
        }

        let versionFileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("VERSION")
        guard let version = try? String(contentsOf: versionFileURL, encoding: .utf8) else {
            return nil
        }

        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedVersion.isEmpty ? nil : trimmedVersion
    }
}
