import Darwin
import Foundation

final class SshManager {
    private final class Session {
        let process: Process
        let stdout: DiagnosticPipe
        let stderr: DiagnosticPipe
        var startupFinished = false
        var expectedTermination = false

        init(process: Process, stdout: DiagnosticPipe, stderr: DiagnosticPipe) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    private let stateQueue = DispatchQueue(label: "ProxyTray.SshManager.state")
    private let processFactory: (SshSettings) -> Process
    private let listenerCleanup: ((Int) -> Void)?
    private let startupDelay: TimeInterval
    private var session: Session?

    var onUnexpectedExit: ((String) -> Void)?

    init(
        processFactory: ((SshSettings) -> Process)? = nil,
        listenerCleanup: ((Int) -> Void)? = nil,
        startupDelay: TimeInterval = 1
    ) {
        self.processFactory = processFactory ?? { settings in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.arguments(for: settings)
            return process
        }
        self.listenerCleanup = listenerCleanup
        self.startupDelay = startupDelay
    }

    func start(settings: SshSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        stop()
        do {
            let process = processFactory(settings)
            let stdout = try DiagnosticPipe()
            let stderr = try DiagnosticPipe()
            let session = Session(process: process, stdout: stdout, stderr: stderr)
            process.standardOutput = stdout.pipe
            process.standardError = stderr.pipe

            process.terminationHandler = { [weak self, weak session] proc in
                guard let self, let session else { return }
                let message = Self.terminationMessage(
                    for: proc,
                    stdout: session.stdout.finish(),
                    stderr: session.stderr.finish()
                )
                // Keep the session until delivery so stop/restart can invalidate
                // an exit notification that is already queued on the main thread.
                DispatchQueue.main.async {
                    let startupPending: Bool? = self.stateQueue.sync {
                        guard self.session === session, !session.expectedTermination else {
                            return nil
                        }
                        self.session = nil
                        return !session.startupFinished
                    }
                    guard let startupPending else { return }
                    if startupPending {
                        completion(.failure(NSError(
                            domain: "ProxyTray",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )))
                    } else {
                        self.onUnexpectedExit?(message)
                    }
                }
            }

            do {
                // Register before launch: a short-lived process can terminate
                // before run() returns and must still belong to this session.
                try stateQueue.sync {
                    self.session = session
                    try process.run()
                }
            } catch {
                _ = stdout.finish()
                _ = stderr.finish()
                DispatchQueue.main.async {
                    let shouldReport = self.stateQueue.sync {
                        guard self.session === session, !session.expectedTermination else {
                            return false
                        }
                        self.session = nil
                        return true
                    }
                    if shouldReport { completion(.failure(error)) }
                }
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay) { [weak self] in
                guard let self else { return }
                let shouldComplete = self.stateQueue.sync {
                    guard self.session === session,
                          !session.expectedTermination,
                          !session.startupFinished,
                          process.isRunning else { return false }
                    session.startupFinished = true
                    return true
                }
                if shouldComplete { completion(.success(())) }
            }
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
        }
    }

    func stop() {
        let session = stateQueue.sync {
            let session = self.session
            session?.expectedTermination = true
            self.session = nil
            return session
        }
        if let process = session?.process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        if let listenerCleanup {
            listenerCleanup(1080)
        } else {
            killListeners(on: 1080)
        }
    }

    static func arguments(for settings: SshSettings) -> [String] {
        var arguments = [
            "-N",
            "-D", "1080",
            "-p", "\(settings.port)",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "ConnectTimeout=15",
            "-o", "BatchMode=yes",
            "-o", "PubkeyAuthentication=yes",
            "-o", "PreferredAuthentications=publickey",
            "-o", "PasswordAuthentication=no",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "UseKeychain=yes",
            "-o", "AddKeysToAgent=yes",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null"
        ]
        if let identityFile = settings.identityFile {
            arguments += [
                "-i", identityFile,
                "-o", "IdentitiesOnly=yes"
            ]
        }
        arguments.append("\(settings.username)@\(settings.host)")
        return arguments
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

    private static func terminationMessage(for process: Process, stdout: String, stderr: String) -> String {
        let summary: String
        if process.terminationReason == .uncaughtSignal {
            summary = "SSH terminated by signal \(process.terminationStatus)."
        } else {
            summary = "SSH exited with status \(process.terminationStatus)."
        }
        let diagnostic = stderr.isEmpty ? stdout : stderr
        return diagnostic.isEmpty ? summary : "\(summary)\n\n\(diagnostic)"
    }
}

/// Drains output as it arrives so SSH cannot block on a full pipe. Only the
/// final 16 KiB per stream is retained; finishing never waits for inherited
/// write handles that a subprocess may have left open.
private final class DiagnosticPipe {
    let pipe: Pipe
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private var tail = Data()
    private var truncated = false
    private var reachedEnd = false
    private var finished = false
    private static let limit = 16 * 1024

    init() throws {
        let pipe = Pipe()
        let queue = DispatchQueue(label: "ProxyTray.SshManager.diagnostics")
        let handle = pipe.fileHandleForReading
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.pipe = pipe
        self.queue = queue
        self.descriptor = descriptor
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { try? handle.close() }
        source.resume()
    }

    deinit {
        source.cancel()
    }

    func finish() -> String {
        queue.sync {
            if !finished {
                drain()
                finished = true
                source.cancel()
            }
            let text = String(decoding: tail, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return truncated ? "[Earlier SSH output omitted]\n\(text)" : text
        }
    }

    private func drain() {
        guard !finished, !reachedEnd else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                tail.append(contentsOf: buffer.prefix(count))
                if tail.count > Self.limit {
                    tail.removeFirst(tail.count - Self.limit)
                    truncated = true
                }
            } else if count < 0, errno == EINTR {
                continue
            } else {
                if count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK) {
                    reachedEnd = true
                    source.cancel()
                }
                return
            }
        }
    }
}
