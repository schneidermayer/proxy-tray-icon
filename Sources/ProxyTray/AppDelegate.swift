import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let controller = ProxyController()

    static func main() {
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

        menu.addItem(withTitle: "Enable Proxy", action: #selector(toggleProxy), keyEquivalent: "")
        menu.addItem(withTitle: "Disable Proxy", action: #selector(disableProxy), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let routeAllItem = NSMenuItem(title: "Route All Traffic", action: #selector(toggleRouteAll), keyEquivalent: "")
        routeAllItem.state = controller.state.routeAll ? .on : .off
        menu.addItem(routeAllItem)

        menu.addItem(withTitle: "Open Whitelist File", action: #selector(openWhitelist), keyEquivalent: "")
        menu.addItem(withTitle: "Update SSH Settings", action: #selector(updateSshSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Update SSH Password", action: #selector(updatePassword), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Cleanup (stop proxy)", action: #selector(cleanup), keyEquivalent: "")
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.image = IconFactory.icon(active: false)
        statusItem.button?.imagePosition = .imageLeading
    }

    @objc private func toggleProxy() { controller.enableProxy() }
    @objc private func disableProxy() { controller.disableProxy() }
    @objc private func toggleRouteAll() { controller.toggleRouteAll() }
    @objc private func openWhitelist() { controller.openWhitelist() }
    @objc private func updateSshSettings() { controller.promptForSshSettings() }
    @objc private func cleanup() { controller.cleanup() }
    @objc private func updatePassword() { controller.promptForPassword() }
    @objc private func quit() { controller.cleanup(); NSApp.terminate(nil) }

    private func refreshUI(state: ProxyState) {
        statusItem.button?.image = IconFactory.icon(active: state.proxyActive)
        menu.item(at: 0)?.isEnabled = !state.proxyActive
        menu.item(at: 1)?.isEnabled = state.proxyActive
        if let routeAllItem = menu.items.first(where: { $0.action == #selector(toggleRouteAll) }) {
            routeAllItem.state = state.routeAll ? .on : .off
            routeAllItem.title = state.routeAll ? "Route All Traffic (on)" : "Route All Traffic"
        }
        if let cleanupItem = menu.items.first(where: { $0.action == #selector(cleanup) }) {
            cleanupItem.isEnabled = !state.proxyActive
        }
    }
}
