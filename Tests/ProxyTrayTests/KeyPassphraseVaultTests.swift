import Foundation
import XCTest
@testable import ProxyTray

final class KeyPassphraseVaultTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyTrayVaultTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testUnencryptedKeyNeedsNoAskpassOrKeychainWrite() throws {
        let key = try makePrivateKeyFixture(in: directory)
        try KeyPassphraseVault().preparePrivateKey(
            identityPath: key.path,
            passphrase: nil,
            askPassExecutablePath: "/nonexistent-proxytray-test-askpass"
        )
    }

    func testEncryptedKeyWithoutPassphraseFailsBeforeKeychainWrite() throws {
        let key = try makePrivateKeyFixture(in: directory, encrypted: true)
        XCTAssertThrowsError(try KeyPassphraseVault().preparePrivateKey(
            identityPath: key.path,
            passphrase: nil,
            askPassExecutablePath: "/nonexistent-proxytray-test-askpass"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("requires a passphrase"))
        }
    }

    func testMalformedKeyReportsOriginalValidationErrorBeforeKeychainWrite() throws {
        let key = directory.appendingPathComponent("corrupt-key")
        try Data("-----BEGIN OPENSSH PRIVATE KEY-----\ncorrupt\n".utf8).write(to: key)
        XCTAssertThrowsError(try KeyPassphraseVault().preparePrivateKey(
            identityPath: key.path,
            passphrase: nil,
            askPassExecutablePath: "/nonexistent-proxytray-test-askpass"
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("invalid format"), error.localizedDescription)
        }
    }
}
