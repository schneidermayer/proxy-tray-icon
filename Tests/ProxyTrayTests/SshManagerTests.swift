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

    func testSSHArgumentsUseOnlyImportedIdentityAndMacOSKeychain() {
        let settings = SshSettings(
            host: "proxy.example.com",
            username: "proxy-user",
            port: 2222,
            identityFile: "/tmp/proxytray-test-identity"
        )

        let arguments = SshManager.arguments(for: settings)

        XCTAssertTrue(arguments.containsOption("BatchMode=yes"))
        XCTAssertTrue(arguments.containsOption("IdentitiesOnly=yes"))
        XCTAssertTrue(arguments.containsOption("UseKeychain=yes"))
        XCTAssertTrue(arguments.containsOption("AddKeysToAgent=yes"))
        XCTAssertTrue(arguments.containsOption("PasswordAuthentication=no"))
        XCTAssertTrue(arguments.containsOption("KbdInteractiveAuthentication=no"))
        XCTAssertEqual(arguments.value(after: "-i"), "/tmp/proxytray-test-identity")
    }

    func testStartupFailureIncludesExitStatusAndPrefersStderr() {
        let (manager, _) = makeManager(script: "printf 'stdout detail'; printf 'connection refused' >&2; exit 23")
        defer { manager.stop() }
        let failed = expectation(description: "Startup failure")
        manager.onUnexpectedExit = { _ in XCTFail("Startup failure must only call completion") }

        manager.start(settings: .defaultSettings) { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .failure(let error) = result else {
                return XCTFail("An exited process must not report success")
            }
            XCTAssertEqual(error.localizedDescription, "SSH exited with status 23.\n\nconnection refused")
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
    }

    func testStartupFailureFallsBackToStdout() {
        let (manager, _) = makeManager(script: "printf 'remote host closed the connection'; exit 7")
        defer { manager.stop() }
        let failed = expectation(description: "Stdout diagnostic")

        manager.start(settings: .defaultSettings) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual(error.localizedDescription, "SSH exited with status 7.\n\nremote host closed the connection")
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
    }

    func testSilentCleanExitStillReportsClosedConnection() {
        let (manager, _) = makeManager(script: "exit 0")
        defer { manager.stop() }
        let failed = expectation(description: "Clean SSH exit")

        manager.start(settings: .defaultSettings) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected closed connection") }
            XCTAssertEqual(error.localizedDescription, "SSH exited with status 0.")
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
    }

    func testUnexpectedExitAfterStartupIncludesSignalAndStderr() {
        let (manager, process) = makeManager(
            script: "printf 'server stopped responding' >&2; exec /bin/sleep 30",
            startupDelay: 0.05
        )
        defer { manager.stop() }
        let started = expectation(description: "Startup success")
        let exited = expectation(description: "Unexpected signal")
        manager.onUnexpectedExit = { message in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(message, "SSH terminated by signal 15.\n\nserver stopped responding")
            exited.fulfill()
        }
        manager.start(settings: .defaultSettings) { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .success = result else { return XCTFail("Expected startup success") }
            started.fulfill()
        }
        wait(for: [started], timeout: 5)

        process.terminate()

        wait(for: [exited], timeout: 5)
    }

    func testLargeOutputIsDrainedAndOnlyDiagnosticTailIsRetained() {
        let script = """
        /usr/bin/awk 'BEGIN { for (i = 0; i < 32768; i++) printf "stdout-output" }'
        /usr/bin/awk 'BEGIN { print "discard-this-prefix"; for (i = 0; i < 32768; i++) printf "stderr-output"; print "\\nfinal connection error" }' >&2
        exit 42
        """
        let (manager, _) = makeManager(script: script, startupDelay: 10)
        defer { manager.stop() }
        let failed = expectation(description: "Large output does not block child")

        manager.start(settings: .defaultSettings) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("SSH exited with status 42.\n\n[Earlier SSH output omitted]"))
            XCTAssertTrue(message.hasSuffix("final connection error"))
            XCTAssertFalse(message.contains("discard-this-prefix"))
            XCTAssertFalse(message.contains("stdout-output"))
            XCTAssertLessThan(message.utf8.count, 17_000)
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
    }

    func testInvalidUTF8DoesNotDiscardErrorOutput() {
        let (manager, _) = makeManager(script: "printf '\\377connection lost' >&2; exit 9")
        defer { manager.stop() }
        let failed = expectation(description: "Lossy UTF8 diagnostic")

        manager.start(settings: .defaultSettings) { result in
            guard case .failure(let error) = result else { return XCTFail("Expected failure") }
            XCTAssertTrue(error.localizedDescription.hasPrefix("SSH exited with status 9."))
            XCTAssertTrue(error.localizedDescription.hasSuffix("connection lost"))
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
    }

    func testIntentionalStopDuringStartupIsQuiet() {
        let (manager, _) = makeManager(script: "exec /bin/sleep 30", startupDelay: 0.05)
        let reported = expectation(description: "No callback after cancelled startup")
        reported.isInverted = true
        manager.onUnexpectedExit = { _ in reported.fulfill() }
        manager.start(settings: .defaultSettings) { _ in reported.fulfill() }

        manager.stop()

        wait(for: [reported], timeout: 0.2)
    }

    func testIntentionalStopAfterStartupIsQuiet() {
        let (manager, _) = makeManager(script: "exec /bin/sleep 30", startupDelay: 0.05)
        let started = expectation(description: "Startup success")
        let reported = expectation(description: "No unexpected exit on stop")
        reported.isInverted = true
        manager.onUnexpectedExit = { _ in reported.fulfill() }
        manager.start(settings: .defaultSettings) { result in
            guard case .success = result else { return XCTFail("Expected startup success") }
            started.fulfill()
        }
        wait(for: [started], timeout: 5)

        manager.stop()

        wait(for: [reported], timeout: 0.2)
    }

    func testRestartSuppressesOldSessionExitAndCompletion() {
        let firstProcess = shellProcess(script: "printf 'old error' >&2; exit 12")
        let secondProcess = shellProcess(script: "exec /bin/sleep 30")
        var invocation = 0
        let manager = SshManager(
            processFactory: { _ in
                invocation += 1
                return invocation == 1 ? firstProcess : secondProcess
            },
            listenerCleanup: { _ in },
            startupDelay: 0.05
        )
        defer { manager.stop() }
        let started = expectation(description: "Replacement startup success")
        manager.onUnexpectedExit = { _ in XCTFail("Old session must not report a disconnect") }
        manager.start(settings: .defaultSettings) { _ in XCTFail("Old session completion must be suppressed") }
        // Keep main-thread delivery queued until the replacement is registered.
        let deadline = Date().addingTimeInterval(5)
        while firstProcess.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertFalse(firstProcess.isRunning)

        manager.start(settings: .defaultSettings) { result in
            guard case .success = result else { return XCTFail("Expected replacement startup success") }
            started.fulfill()
        }

        wait(for: [started], timeout: 5)
    }

    func testLaunchFailureIsDeliveredOnMainThread() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/nonexistent-proxytray-test-executable")
        let manager = SshManager(processFactory: { _ in process }, listenerCleanup: { _ in })
        defer { manager.stop() }
        let failed = expectation(description: "Launch failure")
        manager.onUnexpectedExit = { _ in XCTFail("Launch failure must only call completion") }

        manager.start(settings: .defaultSettings) { result in
            XCTAssertTrue(Thread.isMainThread)
            guard case .failure = result else { return XCTFail("Expected launch failure") }
            failed.fulfill()
        }

        wait(for: [failed], timeout: 5)
    }

    private func makeManager(script: String, startupDelay: TimeInterval = 1) -> (SshManager, Process) {
        let process = shellProcess(script: script)
        let manager = SshManager(
            processFactory: { _ in process },
            listenerCleanup: { _ in },
            startupDelay: startupDelay
        )
        return (manager, process)
    }

    private func shellProcess(script: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        return process
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
