import Foundation

final class SshManager {
    private var task: Process?
    private var askPassURL: URL?

    func start(settings: SshSettings, password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        do {
            let helperURL = try writeAskPass(password: password)
            askPassURL = helperURL

            let process = Process()
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
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            var completed = false
            process.terminationHandler = { [weak self] proc in
                guard proc.terminationStatus == 0 else {
                    if !completed {
                        completed = true
                        completion(.failure(NSError(domain: "ProxyTray", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "SSH exited with status \(proc.terminationStatus)"])))
                    }
                    self?.cleanupAskPass()
                    return
                }
                self?.cleanupAskPass()
            }
            try process.run()
            self.task = process
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if process.isRunning && !completed {
                    completed = true
                    completion(.success(()))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    func stop() {
        if let proc = task {
            if proc.isRunning {
                proc.terminate()
                proc.waitUntilExit()
            }
            task = nil
        }
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
        if let url = askPassURL {
            try? FileManager.default.removeItem(at: url)
        }
        askPassURL = nil
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
}
