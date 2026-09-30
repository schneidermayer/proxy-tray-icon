import Darwin
import Foundation

final class SshManager {
    private final class Session {
        let process: Process
        let stdout: DiagnosticPipe
        let stderr: DiagnosticPipe
        var startupFinished = false
        var expectedTermination = false
        var startupFailure: String?

        init(process: Process, stdout: DiagnosticPipe, stderr: DiagnosticPipe) {
            self.process = process
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    private let stateQueue = DispatchQueue(label: "ProxyTray.SshManager.state")
    private let readinessQueue = DispatchQueue(label: "ProxyTray.SshManager.readiness", qos: .utility)
    private let processFactory: (SshSettings) -> Process
    private let readinessProbe: (Process) -> Bool
    private let inheritedTunnelProbe: () -> Bool
    private let stopInheritedTunnel: () -> Void
    private let control: SshTunnelControl
    private let startupTimeout: TimeInterval
    private let pollInterval: TimeInterval
    private var session: Session?

    var onUnexpectedExit: ((String) -> Void)?

    init(
        controlDirectory: URL = SshTunnelControl.defaultDirectory,
        processFactory: ((SshSettings) -> Process)? = nil,
        readinessProbe: ((Process) -> Bool)? = nil,
        inheritedTunnelProbe: (() -> Bool)? = nil,
        stopInheritedTunnel: (() -> Void)? = nil,
        startupTimeout: TimeInterval = 20,
        pollInterval: TimeInterval = 0.1
    ) {
        let control = SshTunnelControl(directory: controlDirectory)
        self.control = control
        self.processFactory = processFactory ?? { settings in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = Self.arguments(for: settings, controlPath: control.socketPath)
            return process
        }
        self.readinessProbe = readinessProbe ?? { process in
            control.isReady(expectedPID: process.processIdentifier)
        }
        self.inheritedTunnelProbe = inheritedTunnelProbe ?? { control.isReady() }
        self.stopInheritedTunnel = stopInheritedTunnel ?? { control.stop() }
        self.startupTimeout = startupTimeout
        self.pollInterval = pollInterval
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
                    let outcome: (startupPending: Bool, failure: String?)? = self.stateQueue.sync {
                        guard self.session === session, !session.expectedTermination else {
                            return nil
                        }
                        self.session = nil
                        return (!session.startupFinished, session.startupFailure)
                    }
                    guard let outcome else { return }
                    let message = outcome.failure.map { "\($0)\n\n\(message)" } ?? message
                    if outcome.startupPending {
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
                stateQueue.sync { self.session = session }
                try control.prepareDirectory()
                try stateQueue.sync {
                    guard self.session === session, !session.expectedTermination else { return }
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

            awaitReadiness(
                for: session,
                deadline: Date().addingTimeInterval(startupTimeout),
                completion: completion
            )
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
        if let process = session?.process {
            SshTunnelControl.terminateOwnedProcess(process)
        } else {
            stopInheritedTunnel()
        }
    }

    func isTunnelRunning() -> Bool {
        inheritedTunnelProbe()
    }

    private func awaitReadiness(
        for session: Session,
        deadline: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        readinessQueue.asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self else { return }
            let isCurrent = self.stateQueue.sync {
                self.session === session && !session.expectedTermination && !session.startupFinished
            }
            guard isCurrent, session.process.isRunning else { return }
            if self.readinessProbe(session.process) {
                DispatchQueue.main.async {
                    let shouldComplete = self.stateQueue.sync {
                        guard self.session === session,
                              !session.expectedTermination,
                              !session.startupFinished,
                              session.process.isRunning else { return false }
                        session.startupFinished = true
                        return true
                    }
                    if shouldComplete { completion(.success(())) }
                }
            } else if Date() >= deadline {
                let shouldTerminate = self.stateQueue.sync {
                    guard self.session === session, !session.expectedTermination else { return false }
                    session.startupFailure = "Timed out waiting for the authenticated SSH connection to open its SOCKS listener on 127.0.0.1:1080."
                    return true
                }
                if shouldTerminate { SshTunnelControl.terminateOwnedProcess(session.process) }
            } else {
                self.awaitReadiness(for: session, deadline: deadline, completion: completion)
            }
        }
    }

    static func arguments(
        for settings: SshSettings,
        controlPath: String = SshTunnelControl.defaultDirectory.appendingPathComponent("ssh.sock").path
    ) -> [String] {
        var arguments = [
            "-N",
            "-D", "127.0.0.1:1080",
            "-S", controlPath,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no",
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
            "-o", "StrictHostKeyChecking=yes"
        ]
        if let identityFile = settings.identityFile {
            arguments += [
                "-i", identityFile,
                "-o", "IdentitiesOnly=yes"
            ]
        }
        arguments += ["--", "\(settings.username)@\(settings.host)"]
        return arguments
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
final class DiagnosticPipe {
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
