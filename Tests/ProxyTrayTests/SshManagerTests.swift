import XCTest
@testable import ProxyTray

final class SshManagerTests: XCTestCase {
    func testSSHArgumentsRequireNonInteractivePublicKeyAuthentication() {
        let settings = SshSettings(host: "proxy.example.com", username: "proxy-user", port: 2222)

        let arguments = SshManager.arguments(for: settings)

        XCTAssertTrue(arguments.containsOption("BatchMode=yes"))
        XCTAssertTrue(arguments.containsOption("PubkeyAuthentication=yes"))
        XCTAssertTrue(arguments.containsOption("PreferredAuthentications=publickey"))
        XCTAssertTrue(arguments.containsOption("PasswordAuthentication=no"))
        XCTAssertTrue(arguments.containsOption("KbdInteractiveAuthentication=no"))
        XCTAssertEqual(arguments.suffix(1), ["proxy-user@proxy.example.com"])
        XCTAssertEqual(arguments.value(after: "-p"), "2222")
    }
}

private extension Array where Element == String {
    func containsOption(_ option: String) -> Bool {
        indices.contains { index in
            self[index] == "-o" && index + 1 < count && self[index + 1] == option
        }
    }

    func value(after argument: String) -> String? {
        guard let index = firstIndex(of: argument), index + 1 < count else { return nil }
        return self[index + 1]
    }
}
