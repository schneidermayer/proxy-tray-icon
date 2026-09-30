import Foundation
import XCTest
@testable import ProxyTray

final class ProxyControllerTests: XCTestCase {
    private var directory: URL!
    private var config: ConfigManager!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("pt-controller-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        config = ConfigManager(baseDir: directory.appendingPathComponent("config"))
        config.ensureFilesExist()
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testProxySettingsAreAppliedOnlyAfterTunnelReadinessAndRestoredOnDisable() throws {
        let probe = expectation(description: "Readiness probed")
        let active = expectation(description: "Proxy active")
        let gate = ReadinessGate(probe: probe)
        let store = ControllerProxyStore()
        let (ssh, _) = makeSSH(gate: gate)
        let controller = makeController(ssh: ssh, store: store)
        defer { controller.cleanup() }
        controller.onStateChange = { if $0.proxyActive { active.fulfill() } }

        controller.enableProxy()
        wait(for: [probe], timeout: 2)

        XCTAssertTrue(controller.state.connecting)
        XCTAssertFalse(controller.state.proxyActive)
        XCTAssertEqual(store.writeCount, 0)
        gate.allowConnection()
        wait(for: [active], timeout: 2)
        XCTAssertFalse(controller.state.connecting)
        XCTAssertTrue(try store.read(service: store.service).socksEnabled)

        controller.disableProxy()

        XCTAssertFalse(controller.state.proxyActive)
        XCTAssertEqual(store.current, store.original)
    }

    func testCancellingConnectionDoesNotApplyProxyOrReportFailure() {
        let probe = expectation(description: "Readiness probed")
        let activated = expectation(description: "Cancelled connection stays inactive")
        activated.isInverted = true
        let gate = ReadinessGate(probe: probe)
        let store = ControllerProxyStore()
        let (ssh, process) = makeSSH(gate: gate)
        let controller = makeController(ssh: ssh, store: store)
        defer { controller.cleanup() }
        controller.onStateChange = { if $0.proxyActive { activated.fulfill() } }
        controller.enableProxy()
        wait(for: [probe], timeout: 2)

        controller.disableProxy()
        gate.allowConnection()
        wait(for: [activated], timeout: 0.1)

        XCTAssertFalse(controller.state.connecting)
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testFailedProxyActivationStopsTunnelBeforePresentingError() {
        let failed = expectation(description: "Activation error")
        let gate = ReadinessGate()
        gate.allowConnection()
        let store = ControllerProxyStore()
        store.failWrites = true
        let (ssh, process) = makeSSH(gate: gate)
        let controller = makeController(ssh: ssh, store: store, errorPresenter: { message in
            XCTAssertFalse(process.isRunning)
            XCTAssertTrue(message.contains("Simulated preference failure"))
            failed.fulfill()
        })
        defer { controller.cleanup() }

        controller.enableProxy()
        wait(for: [failed], timeout: 2)

        XCTAssertFalse(controller.state.proxyActive)
        XCTAssertFalse(controller.state.connecting)
        XCTAssertEqual(store.current, store.original)
    }

    func testLostConnectionRestoresSettingsAndReportsSSHDetails() {
        let active = expectation(description: "Proxy active")
        let lost = expectation(description: "Connection loss reported")
        let gate = ReadinessGate()
        gate.allowConnection()
        let store = ControllerProxyStore()
        let (ssh, process) = makeSSH(gate: gate)
        let controller = makeController(ssh: ssh, store: store, lossReporter: { message, cleanupErrors in
            XCTAssertTrue(message.contains("signal 15"))
            XCTAssertTrue(cleanupErrors.isEmpty)
            XCTAssertEqual(store.current, store.original)
            lost.fulfill()
        })
        defer { controller.cleanup() }
        controller.onStateChange = { if $0.proxyActive { active.fulfill() } }
        controller.enableProxy()
        wait(for: [active], timeout: 2)

        process.terminate()
        wait(for: [lost], timeout: 2)

        XCTAssertFalse(controller.state.proxyActive)
    }

    private func makeController(
        ssh: SshManager,
        store: ControllerProxyStore,
        errorPresenter: @escaping (String) -> Void = { XCTFail($0) },
        lossReporter: @escaping (String, [String]) -> Void = { message, _ in XCTFail(message) }
    ) -> ProxyController {
        ProxyController(
            config: config,
            network: NetworkConfigurator(store: store, stateURL: directory.appendingPathComponent("network-state.json")),
            ssh: ssh,
            routeAll: true,
            errorPresenter: errorPresenter,
            connectionLossReporter: lossReporter
        )
    }

    private func makeSSH(gate: ReadinessGate) -> (SshManager, Process) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let ssh = SshManager(
            controlDirectory: directory.appendingPathComponent("run"),
            processFactory: { _ in process },
            readinessProbe: { _ in gate.isReady() },
            inheritedTunnelProbe: { false },
            stopInheritedTunnel: {},
            startupTimeout: 2,
            pollInterval: 0.01
        )
        return (ssh, process)
    }
}

private final class ReadinessGate {
    private let lock = NSLock()
    private var ready = false
    private var probe: XCTestExpectation?

    init(probe: XCTestExpectation? = nil) { self.probe = probe }

    func allowConnection() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    func isReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        probe?.fulfill()
        probe = nil
        return ready
    }
}

private final class ControllerProxyStore: NetworkProxyStore {
    let service = NetworkProxyService(id: "test-service", name: "Test Network")
    let original = try! NetworkProxySettings(configuration: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.test/original.pac"])
    lazy var current = original
    var writeCount = 0
    var failWrites = false

    func services() throws -> [NetworkProxyService] { [service] }
    func read(service: NetworkProxyService) throws -> NetworkProxySettings { current }
    func write(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) throws {
        XCTAssertEqual(current, expected)
        writeCount += 1
        if failWrites {
            throw NSError(domain: "ProxyControllerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated preference failure"])
        }
        current = desired
    }
}
