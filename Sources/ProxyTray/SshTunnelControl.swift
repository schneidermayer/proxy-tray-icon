import Darwin
import Foundation

/// Only the master reached through ProxyTray's private control socket belongs
/// to this app. A process listening on the SOCKS port alone is never adopted.
struct SshTunnelControl {
    typealias CommandRunner = (String, [String]) -> (status: Int32, output: String)?

    let directory: URL
    private let commandRunner: CommandRunner
    var socketPath: String { directory.appendingPathComponent("ssh.sock").path }

    init(directory: URL, commandRunner: CommandRunner? = nil) {
        self.directory = directory
        self.commandRunner = commandRunner ?? { executable, arguments in
            Self.runCommand(executable: executable, arguments: arguments)
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".proxy-tray/run", isDirectory: true)
    }

    func prepareDirectory() throws {
        // Darwin's sockaddr_un.sun_path allows 104 bytes, including the NUL.
        guard socketPath.utf8.count < 104 else {
            throw error("The SSH control socket path is too long: \(socketPath)")
        }
        let parent = directory.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path), !hasTrustedParent {
            throw error("The SSH control parent directory must be owned, non-symlink, and not writable by other users: \(parent.path)")
        }
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard hasPrivateDirectory else {
            throw error("The SSH control directory must be an owned, non-symlink directory with permissions 0700: \(directory.path)")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath) {
            guard attributes[.type] as? FileAttributeType == .typeSocket,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw error("The SSH control path is occupied by an unexpected file: \(socketPath)")
            }
            try removeStaleSocket(attributes: attributes)
        }
    }

    func isReady(expectedPID: Int32? = nil) -> Bool {
        guard let pid = masterPID(), expectedPID == nil || pid == expectedPID else { return false }
        let result = commandRunner(
            "/usr/sbin/lsof",
            ["-nP", "-a", "-p", "\(pid)", "-iTCP:1080", "-sTCP:LISTEN", "-t"]
        )
        return result?.status == 0 && result?.output
            .split(whereSeparator: \.isNewline)
            .contains(where: { Int32($0) == pid }) == true
    }

    func stop() {
        guard hasOwnedSocket else { return }
        // -O exit cannot establish a new SSH/network connection. It only
        // requests shutdown from the master at this exact control socket.
        guard controlCommand("exit")?.status == 0 else { return }
        let deadline = Date().addingTimeInterval(1)
        while FileManager.default.fileExists(atPath: socketPath) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private var hasTrustedParent: Bool {
        let parent = directory.deletingLastPathComponent()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: parent.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o022 == 0
    }

    private var hasPrivateDirectory: Bool {
        guard hasTrustedParent, let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeDirectory
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
    }

    private var hasOwnedSocket: Bool {
        guard hasPrivateDirectory,
              let attributes = try? FileManager.default.attributesOfItem(atPath: socketPath) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeSocket
            && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
            && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0
    }

    private func masterPID() -> Int32? {
        guard hasOwnedSocket,
              let result = controlCommand("check"), result.status == 0,
              let start = result.output.range(of: "(pid="),
              let end = result.output[start.upperBound...].firstIndex(of: ")") else {
            return nil
        }
        return Int32(result.output[start.upperBound..<end])
    }

    private func controlCommand(_ command: String) -> (status: Int32, output: String)? {
        commandRunner(
            "/usr/bin/ssh",
            ["-F", "/dev/null", "-S", socketPath, "-O", command, "proxytray-control"]
        )
    }

    private func removeStaleSocket(attributes: [FileAttributeKey: Any]) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw error("Could not inspect SSH control socket: \(socketPath)") }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) >= 0 else {
            throw error("Could not inspect SSH control socket without blocking: \(socketPath)")
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        let connectionError = errno
        guard result < 0, connectionError == ECONNREFUSED else {
            throw error("An active or inaccessible SSH control socket remains at \(socketPath). Stop the existing managed connection before starting another one.")
        }
        // Only ECONNREFUSED proves there is no Unix listener. Timeouts, access
        // errors and successful connections never permit removing the socket.
        guard hasOwnedSocket,
              let originalInode = attributes[.systemFileNumber] as? NSNumber,
              let originalDevice = attributes[.systemNumber] as? NSNumber,
              let current = try? FileManager.default.attributesOfItem(atPath: socketPath),
              current[.systemFileNumber] as? NSNumber == originalInode,
              current[.systemNumber] as? NSNumber == originalDevice else {
            throw error("The SSH control socket changed while it was being inspected: \(socketPath)")
        }
        try FileManager.default.removeItem(atPath: socketPath)
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "ProxyTray", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func runCommand(executable: String, arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        guard let output = try? DiagnosticPipe() else { return nil }
        process.standardOutput = output.pipe
        process.standardError = output.pipe
        do {
            try process.run()
        } catch {
            _ = output.finish()
            return nil
        }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            terminateOwnedProcess(process)
            _ = output.finish()
            return nil
        }
        return (process.terminationStatus, output.finish())
    }

    static func terminateOwnedProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            // This PID comes from the Process we launched, never a port scan.
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
