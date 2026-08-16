import Cocoa

struct ProxyState {
    var proxyActive: Bool
    var routeAll: Bool
}

final class ProxyController {
    private let config = ConfigManager()
    private let keyPassphraseVault = KeyPassphraseVault()
    private let network = NetworkConfigurator()
    private let ssh = SshManager()

    private(set) var state = ProxyState(proxyActive: false, routeAll: UserDefaults.standard.bool(forKey: "RouteAll")) {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((ProxyState) -> Void)?

    init() {
        ssh.onUnexpectedExit = { [weak self] _ in
            self?.handleUnexpectedTunnelExit()
        }
    }

    func bootstrap() {
        config.ensureFilesExist()
        detectExistingProxy()
    }

    func enableProxy() {
        guard !state.proxyActive else { return }
        do {
            let sshSettings = try config.loadSshSettings()
            ssh.start(settings: sshSettings) { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        self?.activateSystemProxy()
                    case .failure(let error):
                        self?.presentError(
                            "Could not connect using SSH key authentication. Make sure the imported key and its Keychain passphrase are correct and that the public key is authorized on the server.\n\n\(error.localizedDescription)"
                        )
                    }
                }
            }
        } catch {
            presentError("Missing or invalid SSH settings.\nUse 'Update SSH Settings' first.\n\n\(error.localizedDescription)")
        }
    }

    func disableProxy() {
        cleanup()
    }

    func restartProxy() {
        guard state.proxyActive else { return }
        cleanup()
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
                let identityFile = try configurePrivateKey(
                    selectedPath: keyField.stringValue,
                    currentSettings: current
                )
                let newSettings = SshSettings(
                    host: trimmedHost,
                    username: trimmedUser,
                    port: portValue,
                    identityFile: identityFile
                )
                try config.saveSshSettings(newSettings)
            } catch SettingsFlowError.cancelled {
                return
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
                let pac = try config.writePAC(for: cidrs)
                try network.enablePACProxy(pacURLString: pac.autoProxyURL)
            }
            state.proxyActive = true
        } catch {
            presentError("Failed to update system proxy: \(error.localizedDescription)")
            cleanup()
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
        case .pac where tunnelRunning:
            state.routeAll = false
            UserDefaults.standard.set(false, forKey: "RouteAll")
            state.proxyActive = true
        case .socks, .pac:
            network.disableProxy()
            state.proxyActive = false
        default:
            break
        }
    }

    private func handleUnexpectedTunnelExit() {
        guard state.proxyActive else { return }
        network.disableProxy()
        state.proxyActive = false
    }

    private func configurePrivateKey(
        selectedPath: String,
        currentSettings: SshSettings
    ) throws -> String? {
        let trimmedPath = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            if let currentIdentity = currentSettings.identityFile,
               currentIdentity != config.importedPrivateKeyPath {
                keyPassphraseVault.removeFromOpenSSHKeychain(
                    identityPath: currentIdentity
                )
            }
            keyPassphraseVault.removeFromOpenSSHKeychain(
                identityPath: config.importedPrivateKeyPath
            )
            try config.removeImportedPrivateKey()
            return nil
        }

        let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
        let selectedURL = URL(fileURLWithPath: expandedPath).standardizedFileURL
        let managedURL = URL(fileURLWithPath: config.importedPrivateKeyPath)
            .standardizedFileURL
        let isAlreadyImported = selectedURL.path == managedURL.path
        let requiresPassphrase = try config.privateKeyRequiresPassphrase(at: selectedURL)

        if isAlreadyImported {
            return managedURL.path
        }

        let passphrase: String?
        if requiresPassphrase {
            guard let enteredPassphrase = promptForPrivateKeyPassphrase() else {
                throw SettingsFlowError.cancelled
            }
            passphrase = enteredPassphrase
        } else {
            passphrase = nil
        }

        keyPassphraseVault.removeFromOpenSSHKeychain(
            identityPath: managedURL.path
        )
        let importedPath = try config.importPrivateKey(from: selectedURL)
        if let passphrase {
            let executablePath = Bundle.main.executableURL?.path
                ?? CommandLine.arguments[0]
            try keyPassphraseVault.storeInOpenSSHKeychain(
                passphrase: passphrase,
                identityPath: importedPath,
                askPassExecutablePath: executablePath
            )
        }
        return importedPath
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
