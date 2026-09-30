import Foundation
import XCTest
@testable import ProxyTray

final class ConfigManagerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTrayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testLoadsLegacySSHSettingsWithoutIdentityFile() throws {
        let configDirectory = temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        let manager = ConfigManager(baseDir: configDirectory)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try Data(#"{"host":"proxy.example.com","username":"proxy-user","port":2222}"#.utf8)
            .write(to: URL(fileURLWithPath: manager.sshSettingsPath))

        let settings = try manager.loadSshSettings()

        XCTAssertEqual(settings.host, "proxy.example.com")
        XCTAssertEqual(settings.username, "proxy-user")
        XCTAssertEqual(settings.port, 2222)
        XCTAssertNil(settings.identityFile)
    }

    func testImportsPrivateKeyWithRestrictedPermissions() throws {
        let manager = ConfigManager(
            baseDir: temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        )
        let sourceURL = try makePrivateKeyFixture(in: temporaryDirectory)
        let key = try Data(contentsOf: sourceURL)

        let importedPath = try manager.importPrivateKey(from: sourceURL)

        XCTAssertEqual(importedPath, manager.importedPrivateKeyPath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: importedPath)),
            key
        )
        let keyAttributes = try FileManager.default.attributesOfItem(atPath: importedPath)
        XCTAssertEqual((keyAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: URL(fileURLWithPath: importedPath).deletingLastPathComponent().path
        )
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testReplacingImportedPrivateKeyKeepsRestrictedPermissions() throws {
        let manager = ConfigManager(
            baseDir: temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        )
        let firstSourceURL = try makePrivateKeyFixture(in: temporaryDirectory)
        let secondSourceURL = try makePrivateKeyFixture(in: temporaryDirectory)
        let secondKey = try Data(contentsOf: secondSourceURL)
        _ = try manager.importPrivateKey(from: firstSourceURL)

        let importedPath = try manager.importPrivateKey(from: secondSourceURL)

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: importedPath)),
            secondKey
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: importedPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsPublicKeyFile() throws {
        let manager = ConfigManager(
            baseDir: temporaryDirectory.appendingPathComponent("config", isDirectory: true)
        )
        let sourceURL = temporaryDirectory.appendingPathComponent("identity.pub")
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest fixture\n".utf8)
            .write(to: sourceURL)

        XCTAssertThrowsError(try manager.importPrivateKey(from: sourceURL))
    }

    func testUnencryptedKeyWithPermissiveSourcePermissionsDoesNotRequirePassphrase() throws {
        let manager = ConfigManager(baseDir: temporaryDirectory.appendingPathComponent("config"))
        let keyURL = try makePrivateKeyFixture(in: temporaryDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyURL.path)

        XCTAssertFalse(try manager.privateKeyRequiresPassphrase(at: keyURL))

        let attributes = try FileManager.default.attributesOfItem(atPath: keyURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testEncryptedRealKeyRequiresPassphrase() throws {
        let manager = ConfigManager(baseDir: temporaryDirectory.appendingPathComponent("config"))
        let keyURL = try makePrivateKeyFixture(in: temporaryDirectory, encrypted: true)

        XCTAssertTrue(try manager.privateKeyRequiresPassphrase(at: keyURL))
    }

    func testMalformedKeyReportsFormatErrorInsteadOfRequiringPassphrase() throws {
        let manager = ConfigManager(baseDir: temporaryDirectory.appendingPathComponent("config"))
        let keyURL = temporaryDirectory.appendingPathComponent("corrupt-key")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\ncorrupt\n-----END OPENSSH PRIVATE KEY-----\n".utf8)
            .write(to: keyURL)

        XCTAssertThrowsError(try manager.privateKeyRequiresPassphrase(at: keyURL)) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid format"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(keyURL.path))
        }
    }

    func testStagedKeyHasUniqueManagedPathAndRestrictedPermissions() throws {
        let manager = ConfigManager(baseDir: temporaryDirectory.appendingPathComponent("config"))
        let keyURL = try makePrivateKeyFixture(in: temporaryDirectory)
        let firstPath = try manager.stagePrivateKey(from: keyURL)
        let secondPath = try manager.stagePrivateKey(from: keyURL)

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertNotEqual(firstPath, manager.importedPrivateKeyPath)
        XCTAssertTrue(manager.isManagedPrivateKey(at: firstPath))
        XCTAssertTrue(manager.isManagedPrivateKey(at: manager.importedPrivateKeyPath))
        XCTAssertFalse(manager.isManagedPrivateKey(at: keyURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: firstPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
