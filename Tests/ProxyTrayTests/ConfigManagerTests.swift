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
        let sourceURL = temporaryDirectory.appendingPathComponent("source-key")
        let key = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        test-fixture
        -----END OPENSSH PRIVATE KEY-----
        """
        try Data(key.utf8).write(to: sourceURL)

        let importedPath = try manager.importPrivateKey(from: sourceURL)

        XCTAssertEqual(importedPath, manager.importedPrivateKeyPath)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: importedPath)),
            Data(key.utf8)
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
        let firstSourceURL = temporaryDirectory.appendingPathComponent("first-key")
        let secondSourceURL = temporaryDirectory.appendingPathComponent("second-key")
        let firstKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nfirst\n"
        let secondKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nsecond\n"
        try Data(firstKey.utf8).write(to: firstSourceURL)
        try Data(secondKey.utf8).write(to: secondSourceURL)
        _ = try manager.importPrivateKey(from: firstSourceURL)

        let importedPath = try manager.importPrivateKey(from: secondSourceURL)

        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: importedPath)),
            Data(secondKey.utf8)
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
}
