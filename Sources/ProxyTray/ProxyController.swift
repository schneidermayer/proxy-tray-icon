import Cocoa

struct ProxyState {
    var proxyActive: Bool
    var routeAll: Bool
}

final class ProxyController {
    private let vault = PasswordVault()
    private let config = ConfigManager()
    private let network = NetworkConfigurator()
    private let ssh = SshManager()

    private(set) var state = ProxyState(proxyActive: false, routeAll: UserDefaults.standard.bool(forKey: "RouteAll")) {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((ProxyState) -> Void)?

    func bootstrap() {
        config.ensureFilesExist()
    }

    func enableProxy() {
        guard !state.proxyActive else { return }
        do {
            let sshSettings = try config.loadSshSettings()
            let password = try vault.readPassword()
            ssh.start(settings: sshSettings, password: password) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.activateSystemProxy()
                    case .failure(let error):
                        self?.presentError(error.localizedDescription)
                    }
                }
            }
        } catch {
            presentError("Missing credentials or SSH settings.\nUse 'Update SSH Settings' and 'Update SSH Password' first.\n\n\(error.localizedDescription)")
        }
    }

    func disableProxy() {
        cleanup()
    }

    func toggleRouteAll() {
        state.routeAll.toggle()
        UserDefaults.standard.set(state.routeAll, forKey: "RouteAll")
        if state.proxyActive {
            activateSystemProxy()
        }
    }

    func openWhitelist() {
        config.ensureFilesExist()
        NSWorkspace.shared.open(URL(fileURLWithPath: config.whitelistPath))
    }

    func promptForPassword() {
        let alert = NSAlert()
        alert.messageText = "SSH password"
        alert.informativeText = "The password will be encrypted locally and stored for reuse."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field

        if alert.runModal() == .alertFirstButtonReturn {
            let newPassword = field.stringValue
            do {
                try vault.storePassword(password: newPassword)
            } catch {
                presentError("Could not store password: \(error.localizedDescription)")
            }
        }
    }

    func promptForSshSettings() {
        let alert = NSAlert()
        alert.messageText = "SSH settings"
        alert.informativeText = "These values are stored locally in ~/.proxy-tray/ssh.json."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let current = (try? config.loadSshSettings()) ?? SshSettings.defaultSettings

        let hostField = NSTextField(string: current.host)
        let userField = NSTextField(string: current.username)
        let portField = NSTextField(string: "\(current.port)")
        hostField.placeholderString = "Host"
        userField.placeholderString = "User"
        portField.placeholderString = "Port"
        let portFormatter = NumberFormatter()
        portFormatter.allowsFloats = false
        portFormatter.minimum = 1
        portFormatter.maximum = 65535
        portField.formatter = portFormatter

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        [hostField, userField, portField].forEach { field in
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(field)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
        stack.frame = container.bounds
        container.addSubview(stack)
        alert.accessoryView = container

        if alert.runModal() == .alertFirstButtonReturn {
            let trimmedHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUser = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let portValue = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            let newSettings = SshSettings(host: trimmedHost, username: trimmedUser, port: portValue)
            do {
                try config.saveSshSettings(newSettings)
            } catch {
                presentError("Could not save SSH settings: \(error.localizedDescription)")
            }
        }
    }

    func cleanup() {
        ssh.stop()
        network.disableProxy()
        state.proxyActive = false
    }

    private func activateSystemProxy() {
        do {
            if state.routeAll {
                try network.enableRouteAllProxy()
            } else {
                let cidrs = try config.loadWhitelist()
                let pacPath = try config.writePAC(for: cidrs)
                try network.enablePACProxy(pacPath: pacPath)
            }
            state.proxyActive = true
        } catch {
            presentError("Failed to update system proxy: \(error.localizedDescription)")
            cleanup()
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Proxy agent"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
