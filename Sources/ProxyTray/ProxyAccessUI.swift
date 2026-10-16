import Cocoa
import ServiceManagement

@available(macOS 13.0, *)
enum ProxyAccessUI {
    static func prepareForConnection() -> Bool {
        do {
            if try ProxyHelperManager.shared.prepare() == .enabled { return true }
            showApproval()
        } catch {
            showError(error)
        }
        return false
    }

    static func prepareOnLaunch() {
        do {
            let status = try ProxyHelperManager.shared.prepare()
            if status == .requiresApproval,
               !UserDefaults.standard.bool(forKey: "OfferedPersistentProxyAccess") {
                UserDefaults.standard.set(true, forKey: "OfferedPersistentProxyAccess")
                showApproval()
            }
        } catch {
            showError(error)
        }
    }

    static func showStatus() {
        do {
            guard try ProxyHelperManager.shared.prepare() == .enabled else {
                showApproval()
                return
            }
            let alert = NSAlert()
            alert.messageText = "Proxy access is enabled"
            alert.informativeText = "ProxyTray can change proxy settings without asking for Touch ID each time. You can revoke access in System Settings under General → Login Items & Extensions."
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Open System Settings")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch {
            showError(error)
        }
    }

    private static func showApproval() {
        let alert = NSAlert()
        alert.messageText = "Allow ProxyTray to change proxy settings"
        alert.informativeText = "Enable ProxyTray in Login Items & Extensions under App Background Activity (called Allow in the Background on older macOS versions). macOS will ask for approval once. After that, starting and stopping the proxy will not require Touch ID. Then return to the tray menu and choose Enable Proxy."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not prepare proxy access"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// Installed-bundle diagnostics. Status and check do not change proxy settings;
/// preparation only registers the service for approval by macOS.
enum ProxyHelperCommandLine {
    static func runIfRequested() -> Bool {
        let commands: Set<String> = ["--proxy-helper-status", "--prepare-proxy-helper", "--check-proxy-helper"]
        guard let command = CommandLine.arguments.dropFirst().first,
              commands.contains(command) else { return false }
        guard #available(macOS 13.0, *) else {
            fputs("Persistent proxy access requires macOS 13 or later.\n", stderr)
            exit(1)
        }
        do {
            let manager = ProxyHelperManager.shared
            if command == "--prepare-proxy-helper" {
                print("Proxy helper: \(try manager.prepare())")
            } else if command == "--proxy-helper-status" {
                print("Proxy helper: \(manager.status)")
            } else {
                guard manager.status == .enabled else {
                    throw NSError(domain: "ProxyTray.NetworkHelper", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "Proxy access is not enabled (\(manager.status))."])
                }
                let connection = try ProxyHelperConnection()
                print(try connection.ping())
                do {
                    try connection.write(data: Data("{}".utf8))
                    throw NSError(domain: "ProxyTray.NetworkHelper.Check", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The helper accepted an invalid request."])
                } catch let error as NSError where error.domain == "ProxyTray.NetworkHelper.Request" {
                    print("Signed connection accepted; invalid proxy request rejected. No proxy settings changed.")
                }
            }
            return true
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
