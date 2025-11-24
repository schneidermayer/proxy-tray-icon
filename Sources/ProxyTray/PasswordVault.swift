import Foundation
import CryptoKit
import Security

enum VaultError: Error {
    case keychainFailure(String)
    case encryption(String)
    case missingPassword
}

final class PasswordVault {
    private let keychainService = "ProxyTrayKey"
    private let passwordFile: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".proxy-tray/password.enc")

    func storePassword(password: String) throws {
        let key = try fetchOrCreateKey()
        let sealed = try encrypt(data: Data(password.utf8), key: key)
        try FileManager.default.createDirectory(at: passwordFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try sealed.write(to: passwordFile)
    }

    func readPassword() throws -> String {
        guard let data = try? Data(contentsOf: passwordFile) else { throw VaultError.missingPassword }
        let key = try fetchOrCreateKey()
        let decrypted = try decrypt(data: data, key: key)
        guard let str = String(data: decrypted, encoding: .utf8) else {
            throw VaultError.encryption("Invalid encoding")
        }
        return str
    }

    private func fetchOrCreateKey() throws -> SymmetricKey {
        if let data = try? readKey() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try storeKey(key)
        return key
    }

    private func storeKey(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "encryption-key",
            kSecValueData as String: keyData
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw VaultError.keychainFailure("Unable to write key (status: \(status))")
        }
    }

    private func readKey() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "encryption-key",
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw VaultError.keychainFailure("Unable to read key (status: \(status))")
        }
        return data
    }

    private func encrypt(data: Data, key: SymmetricKey) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(data, using: key)
            return sealed.combined ?? Data()
        } catch {
            throw VaultError.encryption(error.localizedDescription)
        }
    }

    private func decrypt(data: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw VaultError.encryption(error.localizedDescription)
        }
    }
}
