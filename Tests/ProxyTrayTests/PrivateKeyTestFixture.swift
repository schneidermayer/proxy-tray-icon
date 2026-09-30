import Foundation

/// Generates disposable keys without touching ssh-agent or the user's Keychain.
func makePrivateKeyFixture(in directory: URL, encrypted: Bool = false) throws -> URL {
    let keyURL = directory.appendingPathComponent("fixture-\(UUID().uuidString)")
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    process.arguments = ["-q", "-t", "ed25519", "-f", keyURL.path]
    if encrypted {
        let askPassURL = directory.appendingPathComponent("fixture-askpass-\(UUID().uuidString)")
        // This deliberately public test value travels over askpass stdout,
        // never in process arguments or environment variables.
        let script = "#!/bin/sh\nprintf '%s\\n' 'proxytray-test-fixture-passphrase'\n"
        guard FileManager.default.createFile(
            atPath: askPassURL.path,
            contents: Data(script.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            throw NSError(domain: "ProxyTrayTests", code: 1)
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askPassURL.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = "proxytray-test-fixture"
        process.environment = environment
    } else {
        process.arguments! += ["-N", ""]
    }
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    try process.run()
    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(
            domain: "ProxyTrayTests",
            code: Int(process.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: String(data: errorData, encoding: .utf8) ?? "Fixture key generation failed"]
        )
    }
    return keyURL
}
