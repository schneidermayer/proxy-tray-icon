import Foundation

/// Prepares a new, uniquely named identity before committing its settings.
/// Failed imports, key preparation, and atomic settings writes leave the prior
/// identity and its Keychain entry intact.
final class SshSettingsTransaction {
    private let config: ConfigManager
    private let prepareKey: (String, String?) throws -> Void
    private let discardKey: (String) -> Void
    private let saveSettings: (SshSettings) throws -> Void

    init(
        config: ConfigManager,
        prepareKey: @escaping (String, String?) throws -> Void,
        discardKey: @escaping (String) -> Void,
        saveSettings: ((SshSettings) throws -> Void)? = nil
    ) {
        self.config = config
        self.prepareKey = prepareKey
        self.discardKey = discardKey
        self.saveSettings = saveSettings ?? config.saveSshSettings
    }

    func save(settings: SshSettings, selectedKeyPath: String, passphrase: String?) throws {
        try config.validateSshEndpoint(host: settings.host, username: settings.username, port: settings.port)
        let previous = try? config.loadSshSettings()
        let selectedPath = selectedKeyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = settings

        if selectedPath.isEmpty {
            updated.identityFile = nil
            try saveSettings(updated)
            retireKey(previous?.identityFile)
            return
        }

        let selectedURL = URL(fileURLWithPath: NSString(string: selectedPath).expandingTildeInPath)
            .standardizedFileURL
        if let currentPath = previous?.identityFile,
           URL(fileURLWithPath: currentPath).standardizedFileURL == selectedURL {
            // Keeping an existing identity must not delete its saved passphrase
            // or request it again, but corrupt/missing keys still fail validation.
            _ = try config.privateKeyRequiresPassphrase(at: selectedURL)
            updated.identityFile = currentPath
            try saveSettings(updated)
            return
        }

        let stagedPath = try config.stagePrivateKey(from: selectedURL)
        do {
            try prepareKey(stagedPath, passphrase)
            updated.identityFile = stagedPath
            try saveSettings(updated)
        } catch {
            retireKey(stagedPath)
            throw error
        }
        retireKey(previous?.identityFile)
    }

    private func retireKey(_ path: String?) {
        guard let path, config.isManagedPrivateKey(at: path) else { return }
        // Credential removal needs the key file, so it precedes file removal.
        // Retirement is best effort after commit; failed cleanup leaves an
        // unused old key rather than invalidating the newly saved settings.
        discardKey(path)
        try? config.removeManagedPrivateKey(at: path)
    }
}
