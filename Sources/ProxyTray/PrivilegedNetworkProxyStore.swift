import Foundation
import CryptoKit
import ServiceManagement
import ProxyNetwork

final class PrivilegedNetworkProxyStore: NetworkProxyStore {
    private let local = SystemNetworkProxyStore()

    func services() throws -> [NetworkProxyService] { try local.services() }
    func read(service: NetworkProxyService) throws -> NetworkProxySettings { try local.read(service: service) }

    func write(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) throws {
        if #available(macOS 13.0, *) {
            try ProxyHelperManager.shared.requireEnabled()
            try ProxyHelperConnection().write(NetworkProxyWriteRequest(service: service, expected: expected, desired: desired))
        } else {
            try local.write(service: service, expected: expected, desired: desired)
        }
    }
}

@available(macOS 13.0, *)
final class ProxyHelperManager {
    static let shared = ProxyHelperManager()
    private let service = ManagedHelperService()
    private lazy var registration = HelperRegistration(
        service: service,
        loadVersion: { UserDefaults.standard.string(forKey: "RegisteredNetworkHelperVersion") },
        saveVersion: { UserDefaults.standard.set($0, forKey: "RegisteredNetworkHelperVersion") }
    )

    var status: HelperServiceStatus { service.status }

    @discardableResult
    func prepare() throws -> HelperServiceStatus {
        // Validate signing before asking macOS to register a privileged service.
        _ = try HelperCodeIdentity.requirement(for: ProxyNetworkHelperConstants.serviceName)
        let bundle = Bundle.main.bundleURL
        let helper = bundle.appendingPathComponent("Contents/Library/HelperTools/ProxyTrayHelper")
        let plist = bundle.appendingPathComponent("Contents/Library/LaunchDaemons/\(ProxyNetworkHelperConstants.plistName)")
        var hash = SHA256()
        hash.update(data: try Data(contentsOf: helper))
        hash.update(data: try Data(contentsOf: plist))
        let version = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return try registration.prepare(version: version)
    }

    func requireEnabled() throws {
        guard try prepare() == .enabled else {
            throw NSError(domain: "ProxyTray.NetworkHelper", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Allow ProxyTray under System Settings → General → Login Items & Extensions → App Background Activity, then enable the proxy again. This approval is needed only once."
            ])
        }
    }
}

@available(macOS 13.0, *)
private final class ManagedHelperService: HelperServiceManaging {
    private let service = SMAppService.daemon(plistName: ProxyNetworkHelperConstants.plistName)

    var status: HelperServiceStatus {
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try service.register() }

    func unregister() throws {
        let completion = HelperUnregisterCompletion()
        service.unregister { error in completion.finish(error) }
        try completion.wait()
    }
}

private final class HelperUnregisterCompletion {
    private let completed = DispatchSemaphore(value: 0)
    private var error: Error?

    func finish(_ error: Error?) {
        self.error = error
        completed.signal()
    }

    func wait() throws {
        completed.wait()
        if let error { throw error }
    }
}

@available(macOS 13.0, *)
final class ProxyHelperConnection {
    private let connection: NSXPCConnection

    init() throws {
        let requirement = try HelperCodeIdentity.requirement(for: ProxyNetworkHelperConstants.serviceName)
        connection = NSXPCConnection(machServiceName: ProxyNetworkHelperConstants.serviceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyNetworkHelperProtocol.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
    }

    deinit { connection.invalidate() }

    func write(_ request: NetworkProxyWriteRequest) throws {
        try write(data: JSONEncoder().encode(request))
    }

    func write(data: Data) throws {
        var result: Result<Void, Error>?
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { result = .failure($0) }
        guard let helper = proxy as? ProxyNetworkHelperProtocol else { throw unavailable() }
        // Wait for the write's definite result. An arbitrary client timeout can
        // race rollback with a still-pending privileged write and lose ownership.
        helper.write(data) { error in
            result = error.map { .failure(ProxyNetworkHelperError.decode($0)) } ?? .success(())
        }
        guard let result else { throw unavailable() }
        try result.get()
    }

    func ping() throws -> String {
        var result: Result<String, Error>?
        let proxy = connection.synchronousRemoteObjectProxyWithErrorHandler { result = .failure($0) }
        guard let helper = proxy as? ProxyNetworkHelperProtocol else { throw unavailable() }
        helper.ping { result = .success($0) }
        guard let result else { throw unavailable() }
        return try result.get()
    }

    private func unavailable() -> NSError {
        NSError(domain: "ProxyTray.NetworkHelper", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The ProxyTray network helper did not respond. Check Proxy Access in the tray menu."])
    }
}
