import Foundation
import XCTest
@testable import ProxyTray

final class SshSettingsTransactionTests: XCTestCase {
    private var directory: URL!
    private var config: ConfigManager!
    private var current: SshSettings!
    private var originalKeyData: Data!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTrayTransactionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        config = ConfigManager(baseDir: directory.appendingPathComponent("config"))
        let source = try makePrivateKeyFixture(in: directory)
        let path = try config.importPrivateKey(from: source)
        originalKeyData = try Data(contentsOf: URL(fileURLWithPath: path))
        current = SshSettings(host: "old.example.com", username: "old-user", port: 22, identityFile: path)
        try config.saveSshSettings(current)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testPreparationFailurePreservesPreviousKeySettingsAndCredential() throws {
        let candidate = try makePrivateKeyFixture(in: directory, encrypted: true)
        var stagedPath: String?
        var discarded: [String] = []
        let transaction = SshSettingsTransaction(config: config, prepareKey: { path, passphrase in
            stagedPath = path
            XCTAssertNotEqual(path, self.current.identityFile)
            XCTAssertEqual(passphrase, "incorrect-test-value")
            throw self.failure("Incorrect passphrase")
        }, discardKey: { discarded.append($0) })

        XCTAssertThrowsError(try transaction.save(
            settings: replacementSettings,
            selectedKeyPath: candidate.path,
            passphrase: "incorrect-test-value"
        ))

        try assertPreviousConfigurationIntact()
        let staged = try XCTUnwrap(stagedPath)
        XCTAssertEqual(discarded, [staged])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged))
    }

    func testSaveFailureRemovesPreparedCandidateAndPreservesPreviousConfiguration() throws {
        let candidate = try makePrivateKeyFixture(in: directory)
        var prepared: [String] = []
        var discarded: [String] = []
        let transaction = SshSettingsTransaction(config: config, prepareKey: { path, _ in
            prepared.append(path)
        }, discardKey: { discarded.append($0) }, saveSettings: { _ in
            throw self.failure("Settings write failed")
        })

        XCTAssertThrowsError(try transaction.save(settings: replacementSettings, selectedKeyPath: candidate.path, passphrase: nil))

        try assertPreviousConfigurationIntact()
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(discarded, prepared)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(prepared.first)))
    }

    func testImportFailureDoesNotTouchCurrentCredentialOrSettings() throws {
        var prepared: [String] = []
        var discarded: [String] = []
        let transaction = SshSettingsTransaction(config: config, prepareKey: { path, _ in
            prepared.append(path)
        }, discardKey: { discarded.append($0) })

        XCTAssertThrowsError(try transaction.save(
            settings: replacementSettings,
            selectedKeyPath: directory.appendingPathComponent("missing-key").path,
            passphrase: nil
        ))

        try assertPreviousConfigurationIntact()
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertTrue(discarded.isEmpty)
    }

    func testSuccessfulReplacementSwitchesSettingsBeforeRetiringLegacyKey() throws {
        let candidate = try makePrivateKeyFixture(in: directory)
        var preparedPath: String?
        var discarded: [String] = []
        let transaction = SshSettingsTransaction(config: config, prepareKey: { path, _ in
            preparedPath = path
            try self.assertPreviousConfigurationIntact()
        }, discardKey: { path in
            discarded.append(path)
            XCTAssertEqual(try? self.config.loadSshSettings().identityFile, preparedPath)
        })

        try transaction.save(settings: replacementSettings, selectedKeyPath: candidate.path, passphrase: nil)

        let saved = try config.loadSshSettings()
        XCTAssertEqual(saved.host, replacementSettings.host)
        XCTAssertEqual(saved.identityFile, preparedPath)
        XCTAssertEqual(discarded, [current.identityFile!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.identityFile!))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(saved.identityFile))), try Data(contentsOf: candidate))
    }

    func testClearFailureLeavesCurrentKeyAndCredentialIntact() throws {
        var discarded: [String] = []
        let transaction = SshSettingsTransaction(config: config, prepareKey: { _, _ in
            XCTFail("Clearing must not prepare a key")
        }, discardKey: { discarded.append($0) }, saveSettings: { _ in
            throw self.failure("Settings write failed")
        })

        XCTAssertThrowsError(try transaction.save(settings: replacementSettings, selectedKeyPath: "", passphrase: nil))

        try assertPreviousConfigurationIntact()
        XCTAssertTrue(discarded.isEmpty)
    }

    func testClearSavesNoIdentityBeforeRetiringManagedKey() throws {
        var discarded: [String] = []
        let transaction = SshSettingsTransaction(config: config, prepareKey: { _, _ in
            XCTFail("Clearing must not prepare a key")
        }, discardKey: { path in
            discarded.append(path)
            XCTAssertNil(try? self.config.loadSshSettings().identityFile)
        })

        try transaction.save(settings: replacementSettings, selectedKeyPath: "", passphrase: nil)

        XCTAssertNil(try config.loadSshSettings().identityFile)
        XCTAssertEqual(discarded, [current.identityFile!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.identityFile!))
    }

    func testKeepingManagedKeyUpdatesEndpointWithoutChangingCredential() throws {
        let encryptedKey = try makePrivateKeyFixture(in: directory, encrypted: true)
        _ = try config.importPrivateKey(from: encryptedKey)
        originalKeyData = try Data(contentsOf: encryptedKey)
        let transaction = SshSettingsTransaction(config: config, prepareKey: { _, _ in
            XCTFail("Keeping a key must not request its passphrase again")
        }, discardKey: { _ in XCTFail("Keeping a key must not discard its credential") })

        try transaction.save(settings: replacementSettings, selectedKeyPath: current.identityFile!, passphrase: nil)

        let saved = try config.loadSshSettings()
        XCTAssertEqual(saved.host, replacementSettings.host)
        XCTAssertEqual(saved.identityFile, current.identityFile)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: current.identityFile!)), originalKeyData)
    }

    func testKeepingCorruptKeyFailsBeforeSavingEndpoint() throws {
        let originalSettings = try Data(contentsOf: URL(fileURLWithPath: config.sshSettingsPath))
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\ncorrupt\n".utf8)
            .write(to: URL(fileURLWithPath: current.identityFile!))
        let transaction = SshSettingsTransaction(config: config, prepareKey: { _, _ in
            XCTFail("Keeping a key must not replace it")
        }, discardKey: { _ in XCTFail("Validation failure must not discard a credential") })

        XCTAssertThrowsError(try transaction.save(settings: replacementSettings, selectedKeyPath: current.identityFile!, passphrase: nil))

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: config.sshSettingsPath)), originalSettings)
    }

    private var replacementSettings: SshSettings {
        SshSettings(host: "new.example.com", username: "new-user", port: 2222)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ProxyTrayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func assertPreviousConfigurationIntact(file: StaticString = #filePath, line: UInt = #line) throws {
        let saved = try config.loadSshSettings()
        XCTAssertEqual(saved.host, current.host, file: file, line: line)
        XCTAssertEqual(saved.username, current.username, file: file, line: line)
        XCTAssertEqual(saved.identityFile, current.identityFile, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: current.identityFile!)), originalKeyData, file: file, line: line)
    }
}
