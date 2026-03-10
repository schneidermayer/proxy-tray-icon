import Foundation

final class SshManager {
    private let stateQueue = DispatchQueue(label: "ProxyTray.SshManager.state")
    private var task: Process?
    private var askPassURL: URL?
    private var expectedTerminationPIDs: Set<Int32> = []

    var onUnexpectedExit: ((String) -> Void)?

    func start(settings: SshSettings, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        do {
            let helperURL = try writeAskPass(password: password)

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-N",
                "-D", "1080",
                "-p", "\(settings.port)",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "\(settings.username)@\(settings.host)"
            ]
            process.environment = [
                "SSH_ASKPASS": helperURL.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "DISPLAY": "ssh-askpass"
            ]
            process.standardOutput = stdout
            process.standardError = stderr

            let completionQueue = DispatchQueue(label: "ProxyTray.SshManager.startCompletion")
            var completed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                completionQueue.sync {
                    guard !completed else { return }
                    completed = true
                    DispatchQueue.main.async {
                        completion(result)
                    }
                }
            }

            process.terminationHandler = { [weak self] proc in
                let message = self?.terminationMessage(
                    for: proc,
                    stdout: self?.readPipe(stdout) ?? "",
                    stderr: self?.readPipe(stderr) ?? ""
                ) ?? "SSH connection closed."
                self?.clearTaskIfMatching(proc)
                self?.cleanupAskPass()

                if self?.consumeExpectedTermination(for: proc.processIdentifier) == true {
                    return
                }

                let startupPending = completionQueue.sync { !completed }
                if startupPending {
                    finish(.failure(NSError(
                        domain: "ProxyTray",
                        code: Int(proc.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: message]
                    )))
                    return
                }

                DispatchQueue.main.async {
                    self?.onUnexpectedExit?(message)
                }
            }

            stateQueue.sync {
                askPassURL = helperURL
            }
            try process.run()
            stateQueue.sync {
                task = process
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if process.isRunning {
                    finish(.success(()))
                }
            }
        } catch {
            cleanupAskPass()
            completion(.failure(error))
        }
    }

    func stop() {
        let proc = stateQueue.sync { task }
        if let proc, proc.isRunning {
            _ = stateQueue.sync {
                expectedTerminationPIDs.insert(proc.processIdentifier)
            }
            proc.terminate()
            proc.waitUntilExit()
        }
        clearTaskIfMatching(proc)
        cleanupAskPass()
        killListeners(on: 1080)
    }

    private func writeAskPass(password: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("proxytray-askpass.sh")
        let escaped = password.replacingOccurrences(of: "'", with: "'\"'\"'")
        let script = "#!/bin/bash\nprintf '%s\\n' '\(escaped)'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func cleanupAskPass() {
        let url = stateQueue.sync { () -> URL? in
            let current = askPassURL
            askPassURL = nil
            return current
        }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func killListeners(on port: Int) {
        guard let pids = try? listPIDsListening(on: port) else { return }
        for pid in pids {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/bin/kill")
            kill.arguments = ["-9", "\(pid)"]
            try? kill.run()
            kill.waitUntilExit()
        }
    }

    func isTunnelRunning(on port: Int = 1080) -> Bool {
        guard let pids = try? listPIDsListening(on: port) else { return false }
        return !pids.isEmpty
    }

    private func listPIDsListening(on port: Int) throws -> [Int32] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        return output
            .split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func clearTaskIfMatching(_ process: Process?) {
        stateQueue.sync {
            if task === process {
                task = nil
            }
        }
    }

    private func consumeExpectedTermination(for pid: Int32) -> Bool {
        stateQueue.sync {
            expectedTerminationPIDs.remove(pid) != nil
        }
    }

    private func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func terminationMessage(for process: Process, stdout: String, stderr: String) -> String {
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        if process.terminationReason == .uncaughtSignal {
            return "SSH terminated by signal \(process.terminationStatus)."
        }
        if process.terminationStatus == 0 {
            return "SSH connection closed."
        }
        return "SSH exited with status \(process.terminationStatus)."
    }
}
