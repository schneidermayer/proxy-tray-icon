import Cocoa

struct ProxyState {
    var proxyActive: Bool
    var routeAll: Bool
    var connecting = false
}

final class ProxyController {
    private let config: ConfigManager
    private let keyPassphraseVault = KeyPassphraseVault()
    private let network: NetworkConfigurator
    private let ssh: SshManager
    private let errorPresenter: (String) -> Void
    private let connectionLossReporter: (String, [String]) -> Void
    private lazy var existingTunnelMonitor = ExistingTunnelMonitor { [weak self] in
        self?.ssh.isTunnelRunning() ?? false
    }

    private(set) var state: ProxyState {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((ProxyState) -> Void)?

    init(
        config: ConfigManager = ConfigManager(),
        network: NetworkConfigurator = NetworkConfigurator(),
        ssh: SshManager = SshManager(),
        routeAll: Bool = UserDefaults.standard.bool(forKey: "RouteAll"),
        errorPresenter: ((String) -> Void)? = nil,
        connectionLossReporter: ((String, [String]) -> Void)? = nil
    ) {
        self.config = config
        self.network = network
        self.ssh = ssh
        self.errorPresenter = errorPresenter ?? Self.showError
        self.connectionLossReporter = connectionLossReporter ?? ConnectionLossAlert.present
        self.state = ProxyState(proxyActive: false, routeAll: routeAll)
        ssh.onUnexpectedExit = { [weak self] message in
            self?.handleUnexpectedTunnelExit(message: message)
        }
    }

    func bootstrap() {
        config.ensureFilesExist()
        detectExistingProxy()
    }

    func enableProxy() {
        guard !state.proxyActive, !state.connecting else { return }
        existingTunnelMonitor.stop()
        do {
            let sshSettings = try config.loadSshSettings()
            state.connecting = true
            ssh.start(settings: sshSettings) { [weak self] result in
                guard let self else { return }
                self.state.connecting = false
                switch result {
                case .success:
                    self.activateSystemProxy()
                case .failure(let error):
                    self.presentError(Self.connectionErrorMessage(error))
                }
            }
        } catch {
            presentError("Missing or invalid SSH settings.\nUse 'Update SSH Settings' first.\n\n\(error.localizedDescription)")
        }
    }

    func disableProxy() {
        let failures = cleanup()
        if !failures.isEmpty {
            presentError("Could not restore all previous proxy settings:\n\n" + failures.joined(separator: "\n"))
        }
    }

    func restartProxy() {
        guard state.proxyActive else { return }
        let failures = cleanup()
        guard failures.isEmpty else {
            presentError("Could not restore the previous proxy settings before restarting:\n\n" + failures.joined(separator: "\n"))
            return
        }
        enableProxy()
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

    func promptForSshSettings() {
        let alert = NSAlert()
        alert.messageText = "SSH settings"
        alert.informativeText = "The selected private key is copied into ~/.proxy-tray/keys with restricted permissions. Its passphrase is stored in the macOS Keychain."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let current = (try? config.loadSshSettings()) ?? SshSettings.defaultSettings

        let hostField = NSTextField(string: current.host)
        let userField = NSTextField(string: current.username)
        let portField = NSTextField(string: "\(current.port)")
        let keyField = NSTextField(string: current.identityFile ?? "")
        hostField.placeholderString = "Host"
        userField.placeholderString = "User"
        portField.placeholderString = "Port"
        keyField.placeholderString = "No private key imported"
        hostField.identifier = NSUserInterfaceItemIdentifier("ssh-host")
        userField.identifier = NSUserInterfaceItemIdentifier("ssh-username")
        portField.identifier = NSUserInterfaceItemIdentifier("ssh-port")
        keyField.identifier = NSUserInterfaceItemIdentifier("ssh-private-key")
        keyField.isEditable = false
        keyField.isSelectable = true
        keyField.lineBreakMode = .byTruncatingMiddle
        let portFormatter = NumberFormatter()
        portFormatter.allowsFloats = false
        portFormatter.minimum = 1
        portFormatter.maximum = 65535
        portField.formatter = portFormatter

        let keyPicker = PrivateKeyPicker(pathField: keyField)
        let chooseKeyButton = NSButton(
            title: "Choose Key…",
            target: keyPicker,
            action: #selector(PrivateKeyPicker.chooseKey)
        )
        let clearKeyButton = NSButton(
            title: "Clear",
            target: keyPicker,
            action: #selector(PrivateKeyPicker.clearKey)
        )
        let keyRow = NSStackView(views: [keyField, chooseKeyButton, clearKeyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 6
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        keyField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        [hostField, userField, portField].forEach { field in
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
            stack.addArrangedSubview(field)
        }
        stack.addArrangedSubview(keyRow)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 122))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        alert.accessoryView = container

        let response = withExtendedLifetime(keyPicker) {
            alert.runModal()
        }
        if response == .alertFirstButtonReturn {
            let trimmedHost = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUser = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let portValue = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
            do {
                try config.validateSshEndpoint(
                    host: trimmedHost,
                    username: trimmedUser,
                    port: portValue
                )
                let newSettings = SshSettings(
                    host: trimmedHost,
                    username: trimmedUser,
                    port: portValue
                )
                try saveSshSettings(newSettings, selectedKeyPath: keyField.stringValue, currentSettings: current)
            } catch SettingsFlowError.cancelled {
                return
            } catch {
                presentError("Could not save SSH settings: \(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func cleanup() -> [String] {
        existingTunnelMonitor.stop()
        ssh.stop()
        let failures = network.disableProxy()
        state.connecting = false
        state.proxyActive = false
        return failures
    }

    private func activateSystemProxy() {
        do {
            if state.routeAll {
                try network.enableRouteAllProxy()
            } else {
                let cidrs = try config.loadWhitelist()
                let pac = try config.writePAC(for: cidrs)
                try network.enablePACProxy(pacURLString: pac.autoProxyURL)
            }
            state.proxyActive = true
        } catch {
            let failures = cleanup()
            var message = "Failed to update system proxy: \(error.localizedDescription)"
            if !failures.isEmpty {
                message += "\n\nCould not restore the previous settings:\n" + failures.joined(separator: "\n")
            }
            presentError(message)
        }
    }

    private func detectExistingProxy() {
        let netState = network.detectProxyState()
        let tunnelRunning = ssh.isTunnelRunning()
        switch netState {
        case .socks where tunnelRunning:
            state.routeAll = true
            UserDefaults.standard.set(true, forKey: "RouteAll")
            state.proxyActive = true
            monitorExistingTunnel()
        case .pac where tunnelRunning:
            state.routeAll = false
            UserDefaults.standard.set(false, forKey: "RouteAll")
            state.proxyActive = true
            monitorExistingTunnel()
        default:
            // No journal means this is a no-op. Pending or interrupted owned
            // changes are recovered even if they do not form an active proxy.
            let failures = cleanup()
            if !failures.isEmpty {
                presentError("Could not restore proxy settings from the previous session:\n\n" + failures.joined(separator: "\n"))
            }
        }
    }

    private func monitorExistingTunnel() {
        existingTunnelMonitor.start { [weak self] in
            self?.handleUnexpectedTunnelExit(message:
                "The previously running ProxyTray tunnel is no longer available.\n" +
                "SSH error output is unavailable because this connection was started before this app instance."
            )
        }
    }

    private func handleUnexpectedTunnelExit(message: String) {
        guard state.proxyActive else { return }
        existingTunnelMonitor.stop()
        let cleanupErrors = network.disableProxy()
        state.proxyActive = false
        connectionLossReporter(message, cleanupErrors)
    }

    private func saveSshSettings(_ settings: SshSettings, selectedKeyPath: String, currentSettings: SshSettings) throws {
        let trimmedPath = selectedKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var passphrase: String?
        if !trimmedPath.isEmpty {
            let selectedURL = URL(fileURLWithPath: NSString(string: trimmedPath).expandingTildeInPath).standardizedFileURL
            let currentURL = currentSettings.identityFile.map { URL(fileURLWithPath: $0).standardizedFileURL }
            if selectedURL != currentURL,
               try config.privateKeyRequiresPassphrase(at: selectedURL) {
                guard let enteredPassphrase = promptForPrivateKeyPassphrase() else {
                    throw SettingsFlowError.cancelled
                }
                passphrase = enteredPassphrase
            }
        }
        let transaction = SshSettingsTransaction(
            config: config,
            prepareKey: { [keyPassphraseVault] path, passphrase in
                try keyPassphraseVault.preparePrivateKey(
                    identityPath: path,
                    passphrase: passphrase,
                    askPassExecutablePath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
                )
            },
            discardKey: { [keyPassphraseVault] path in
                keyPassphraseVault.removeFromOpenSSHKeychain(identityPath: path)
            }
        )
        try transaction.save(settings: settings, selectedKeyPath: trimmedPath, passphrase: passphrase)
    }

    private static func connectionErrorMessage(_ error: Error) -> String {
        let detail = error.localizedDescription
        var message = "Could not establish the SSH tunnel.\n\n\(detail)"
        let lowercased = detail.lowercased()
        if lowercased.contains("host key verification failed") || lowercased.contains("remote host identification has changed") {
            message += "\n\nVerify the server's host-key fingerprint with its administrator, then connect using SSH in Terminal to establish trust. ProxyTray requires a matching key in your normal SSH known-hosts files."
        }
        return message
    }

    private func promptForPrivateKeyPassphrase() -> String? {
        let alert = NSAlert()
        alert.messageText = "Private key passphrase"
        alert.informativeText = "Enter the passphrase used to unlock this private key. It will be stored securely in the macOS Keychain and is never sent to the SSH server."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Store in Keychain")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Passphrase"
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let passphrase = field.stringValue
        guard !passphrase.isEmpty else {
            presentError("The selected private key requires a passphrase.")
            return nil
        }
        return passphrase
    }

    private func presentError(_ message: String) {
        errorPresenter(message)
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Proxy agent"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

private enum SettingsFlowError: Error {
    case cancelled
}

private final class PrivateKeyPicker: NSObject {
    private weak var pathField: NSTextField?

    init(pathField: NSTextField) {
        self.pathField = pathField
    }

    @objc func chooseKey() {
        let panel = NSOpenPanel()
        panel.title = "Choose SSH Private Key"
        panel.message = "Select the private key file to import into ProxyTray."
        panel.prompt = "Choose Key"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        if let currentPath = pathField?.stringValue, !currentPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath)
                .deletingLastPathComponent()
        } else {
            panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh", isDirectory: true)
        }

        if panel.runModal() == .OK, let selectedURL = panel.url {
            pathField?.stringValue = selectedURL.path
        }
    }

    @objc func clearKey() {
        pathField?.stringValue = ""
    }
}
