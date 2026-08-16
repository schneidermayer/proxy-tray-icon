import Foundation
import Security

enum KeyPassphraseVaultError: LocalizedError {
    case keychainFailure(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            return "Could not access the macOS Keychain (status: \(status))"
        }
    }
}

final class KeyPassphraseVault {
    static let askPassTokenEnvironmentKey = "PROXYTRAY_KEY_PASSPHRASE_TOKEN"

    private let askPassService = "net.hsch.proxytray.ssh-key-passphrase-once"

    func createAskPassToken(for passphrase: String) throws -> String {
        let token = UUID().uuidString
        try storeSecret(passphrase, service: askPassService, account: token)
        return token
    }

    func discardAskPassToken(_ token: String) throws {
        try removeSecret(service: askPassService, account: token)
    }

    func storeInOpenSSHKeychain(
        passphrase: String,
        identityPath: String,
        askPassExecutablePath: String
    ) throws {
        let token = try createAskPassToken(for: passphrase)
        defer { try? discardAskPassToken(token) }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["--apple-use-keychain", identityPath]
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askPassExecutablePath
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "proxytray-askpass"
        environment[Self.askPassTokenEnvironmentKey] = token
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? "Could not store the private key passphrase in the OpenSSH Keychain"
            throw NSError(
                domain: "ProxyTray",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    func removeFromOpenSSHKeychain(identityPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["--apple-use-keychain", "-d", identityPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    @discardableResult
    static func answerAskPassIfRequested() -> Bool {
        guard let token = ProcessInfo.processInfo.environment[askPassTokenEnvironmentKey] else {
            return false
        }
        let vault = KeyPassphraseVault()
        let passphrase = try? vault.readSecret(
            service: vault.askPassService,
            account: token
        )
        try? vault.discardAskPassToken(token)
        guard let passphrase,
              let data = "\(passphrase)\n".data(using: .utf8) else {
            return true
        }
        FileHandle.standardOutput.write(data)
        return true
    }

    private func storeSecret(_ secret: String, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeyPassphraseVaultError.keychainFailure(status)
        }
    }

    private func readSecret(service: String, account: String) throws -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeyPassphraseVaultError.keychainFailure(status)
        }
        return secret
    }

    private func removeSecret(service: String, account: String) throws {
        let status = SecItemDelete(
            baseQuery(service: service, account: account) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyPassphraseVaultError.keychainFailure(status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
