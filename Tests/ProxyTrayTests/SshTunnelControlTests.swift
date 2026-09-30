import Darwin
import XCTest
@testable import ProxyTray

final class SshTunnelControlTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var directory: URL { temporaryDirectory.appendingPathComponent("run") }
    private var socketDescriptor: Int32 = -1

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptc-" + UUID().uuidString.prefix(8), isDirectory: true)
        try SshTunnelControl(directory: directory).prepareDirectory()
    }

    override func tearDownWithError() throws {
        if socketDescriptor >= 0 { Darwin.close(socketDescriptor) }
        try FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testReadinessRequiresControlMasterPIDAndItsOwnListener() throws {
        try bindControlSocket(listening: true)
        var commands: [[String]] = []
        let control = SshTunnelControl(directory: directory) { executable, arguments in
            commands.append(arguments)
            if executable == "/usr/bin/ssh" {
                XCTAssertEqual(arguments.prefix(2), ["-F", "/dev/null"])
                return (0, "Master running (pid=12345)\n")
            }
            XCTAssertEqual(executable, "/usr/sbin/lsof")
            XCTAssertTrue(arguments.contains("-a"))
            XCTAssertTrue(arguments.contains("12345"))
            XCTAssertTrue(arguments.contains("-iTCP:1080"))
            return (0, "12345\n")
        }

        XCTAssertTrue(control.isReady(expectedPID: 12345))
        XCTAssertEqual(commands.count, 2)
        commands.removeAll()
        XCTAssertFalse(control.isReady(expectedPID: 54321))
        XCTAssertEqual(commands.count, 1, "A different master must not satisfy readiness")
    }

    func testListenerFromDifferentProcessDoesNotSatisfyReadiness() throws {
        try bindControlSocket(listening: true)
        let control = SshTunnelControl(directory: directory) { executable, _ in
            executable == "/usr/bin/ssh" ? (0, "Master running (pid=12345)\n") : (0, "54321\n")
        }

        XCTAssertFalse(control.isReady())
    }

    func testNoPrivateSocketNeverRunsControlOrPortCommands() {
        let control = SshTunnelControl(directory: directory) { _, _ in
            XCTFail("An absent managed socket must never trigger adoption or shutdown")
            return nil
        }

        XCTAssertFalse(control.isReady())
        control.stop()
    }

    func testInheritedStopTargetsOnlyPrivateControlSocket() throws {
        try bindControlSocket(listening: true)
        let socketPath = directory.appendingPathComponent("ssh.sock").path
        var commands: [[String]] = []
        let control = SshTunnelControl(directory: directory) { executable, arguments in
            XCTAssertEqual(executable, "/usr/bin/ssh")
            commands.append(arguments)
            try? FileManager.default.removeItem(atPath: socketPath)
            return (0, "Exit request sent.\n")
        }

        control.stop()

        XCTAssertEqual(commands, [["-F", "/dev/null", "-S", socketPath, "-O", "exit", "proxytray-control"]])
    }

    func testPreparationReclaimsOnlyRefusedStaleSocket() throws {
        try bindControlSocket(listening: false)
        Darwin.close(socketDescriptor)
        socketDescriptor = -1
        let control = SshTunnelControl(directory: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: control.socketPath))

        try control.prepareDirectory()

        XCTAssertFalse(FileManager.default.fileExists(atPath: control.socketPath))
    }

    func testPreparationNeverRemovesLiveSocket() throws {
        try bindControlSocket(listening: true)
        let control = SshTunnelControl(directory: directory)

        XCTAssertThrowsError(try control.prepareDirectory())
        XCTAssertTrue(FileManager.default.fileExists(atPath: control.socketPath))
    }

    func testUnexpectedControlFileIsPreserved() throws {
        let control = SshTunnelControl(directory: directory)
        try Data("keep this file".utf8).write(to: URL(fileURLWithPath: control.socketPath))

        XCTAssertThrowsError(try control.prepareDirectory())
        XCTAssertEqual(try String(contentsOfFile: control.socketPath), "keep this file")
    }

    func testUnsafeDirectoryPermissionsPreventControlAccess() throws {
        try bindControlSocket(listening: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: directory.path)
        let control = SshTunnelControl(directory: directory) { _, _ in
            XCTFail("An unsafe control directory must not be used")
            return nil
        }

        XCTAssertThrowsError(try control.prepareDirectory())
        XCTAssertFalse(control.isReady())
        control.stop()
        XCTAssertTrue(FileManager.default.fileExists(atPath: control.socketPath))
    }

    func testSymlinkedControlParentIsRejected() throws {
        let linkedParent = temporaryDirectory.appendingPathComponent("linked")
        let actualParent = temporaryDirectory.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actualParent, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: actualParent)
        let control = SshTunnelControl(directory: linkedParent.appendingPathComponent("run"))

        XCTAssertThrowsError(try control.prepareDirectory())
        XCTAssertFalse(FileManager.default.fileExists(atPath: actualParent.appendingPathComponent("run").path))
    }

    private func bindControlSocket(listening: Bool) throws {
        let control = SshTunnelControl(directory: directory)
        socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(control.socketPath.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: control.socketPath)
        if listening {
            guard Darwin.listen(socketDescriptor, 1) == 0 else { throw POSIXError(.EINVAL) }
        }
    }
}
