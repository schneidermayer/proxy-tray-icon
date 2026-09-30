import Foundation
import Security
import SystemConfiguration

struct NetworkProxyService: Codable {
    let id: String
    let name: String
}

/// Only these six fields can be changed or restored. Credentials and all other
/// proxy protocols remain in SystemConfiguration and are never journaled.
struct NetworkProxySettings: Codable, Equatable {
    static let pacKeys = ["ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ProxyAutoConfigJavaScript"]
    static let socksKeys = ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"]
    private let values: Data
    let authenticatedSOCKS: Bool

    init(configuration: [String: Any]) throws {
        let managed = configuration.filter { (Self.pacKeys + Self.socksKeys).contains($0.key) }
        values = try PropertyListSerialization.data(fromPropertyList: managed, format: .binary, options: 0)
        // SOCKSUser is the public authentication key. Reject additional auth
        // metadata too, including disabled configurations whose secrets cannot
        // be recovered through a proxy-settings read.
        authenticatedSOCKS = configuration.contains { key, value in
            guard key.hasPrefix("SOCKS"), !Self.socksKeys.contains(key) else { return false }
            if let string = value as? String { return !string.isEmpty }
            if let number = value as? NSNumber { return number.boolValue }
            return true
        }
    }

    private init(dictionary: [String: Any], authenticatedSOCKS: Bool) throws {
        values = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
        self.authenticatedSOCKS = authenticatedSOCKS
    }

    func dictionary() throws -> [String: Any] {
        guard let dictionary = try PropertyListSerialization.propertyList(from: values, options: [], format: nil) as? [String: Any],
              dictionary.keys.allSatisfy({ (Self.pacKeys + Self.socksKeys).contains($0) }) else {
            throw NSError(domain: "ProxyTray.Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid saved proxy settings"])
        }
        return dictionary
    }

    func validate() throws { _ = try dictionary() }

    var pacEnabled: Bool { ((try? dictionary()["ProxyAutoConfigEnable"]) as? NSNumber)?.boolValue ?? false }
    var socksEnabled: Bool { ((try? dictionary()["SOCKSEnable"]) as? NSNumber)?.boolValue ?? false }

    func configured(pacURLString: String?) throws -> Self {
        var result = try dictionary()
        result["ProxyAutoConfigEnable"] = pacURLString == nil ? 0 : 1
        result["SOCKSEnable"] = pacURLString == nil ? 1 : 0
        if let pacURLString {
            result["ProxyAutoConfigURLString"] = pacURLString
            result.removeValue(forKey: "ProxyAutoConfigJavaScript")
        } else {
            result["SOCKSProxy"] = "127.0.0.1"
            result["SOCKSPort"] = 1080
        }
        return try Self(dictionary: result, authenticatedSOCKS: authenticatedSOCKS)
    }

    func restoring(_ original: Self, pac: Bool, socks: Bool) throws -> Self {
        var result = try dictionary()
        let previous = try original.dictionary()
        for key in (pac ? Self.pacKeys : []) + (socks ? Self.socksKeys : []) {
            result[key] = previous[key]
        }
        return try Self(dictionary: result, authenticatedSOCKS: authenticatedSOCKS)
    }

    func matchesPAC(_ other: Self) -> Bool { matches(other, keys: Self.pacKeys) }
    func matchesSOCKS(_ other: Self) -> Bool {
        authenticatedSOCKS == other.authenticatedSOCKS && matches(other, keys: Self.socksKeys)
    }

    private func matches(_ other: Self, keys: [String]) -> Bool {
        guard let lhs = try? dictionary(), let rhs = try? other.dictionary() else { return false }
        return NSDictionary(dictionary: lhs.filter { keys.contains($0.key) })
            .isEqual(to: rhs.filter { keys.contains($0.key) })
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.matchesPAC(rhs) && lhs.matchesSOCKS(rhs)
    }
}

protocol NetworkProxyStore {
    func services() throws -> [NetworkProxyService]
    func read(service: NetworkProxyService) throws -> NetworkProxySettings
    func write(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) throws
}

enum NetworkProxyStoreError: LocalizedError {
    case missingService(String)

    var errorDescription: String? {
        switch self {
        case .missingService(let name): return "Network service \"\(name)\" no longer exists"
        }
    }
}

final class SystemNetworkProxyStore: NetworkProxyStore {
    private var authorization: AuthorizationRef?

    deinit {
        if let authorization { AuthorizationFree(authorization, []) }
    }

    func services() throws -> [NetworkProxyService] {
        let preferences = try readPreferences()
        guard let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
            throw systemError("List network services")
        }
        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service),
                  let id = SCNetworkServiceGetServiceID(service),
                  let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  SCNetworkProtocolGetEnabled(proxy) else { return nil }
            return NetworkProxyService(
                id: id as String,
                name: SCNetworkServiceGetName(service) as String? ?? "Unnamed service"
            )
        }
    }

    func read(service: NetworkProxyService) throws -> NetworkProxySettings {
        let configuration = try proxyConfiguration(service: service, preferences: readPreferences()).configuration
        return try NetworkProxySettings(configuration: configuration)
    }

    func write(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) throws {
        let preferences = try writePreferences()
        // Fail promptly if another configuration client holds the lock. Retaining
        // the journal makes this retryable without blocking the menu bar thread.
        guard SCPreferencesLock(preferences, false) else { throw systemError("Lock network preferences") }
        defer { SCPreferencesUnlock(preferences) }
        SCPreferencesSynchronize(preferences)
        let (proxy, configuration) = try proxyConfiguration(service: service, preferences: preferences)
        guard try NetworkProxySettings(configuration: configuration) == expected else {
            throw NSError(domain: "ProxyTray.Network", code: 1, userInfo: [NSLocalizedDescriptionKey: "Proxy settings changed outside ProxyTray before they could be updated"])
        }
        var updated = configuration
        let replacement = try desired.dictionary()
        for key in NetworkProxySettings.pacKeys + NetworkProxySettings.socksKeys {
            updated[key] = replacement[key]
        }
        guard SCNetworkProtocolSetConfiguration(proxy, updated as CFDictionary) else { throw systemError("Set proxy settings") }
        guard SCPreferencesCommitChanges(preferences) else { throw systemError("Commit proxy settings") }
        guard SCPreferencesApplyChanges(preferences) else { throw systemError("Apply proxy settings") }
    }

    private func readPreferences() throws -> SCPreferences {
        guard let preferences = SCPreferencesCreate(nil, "ProxyTray" as CFString, nil) else { throw systemError("Read network preferences") }
        return preferences
    }

    private func writePreferences() throws -> SCPreferences {
        if authorization == nil {
            let status = AuthorizationCreate(nil, nil, [], &authorization)
            guard status == errAuthorizationSuccess else {
                throw NSError(domain: "ProxyTray.Network", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not authorize network preference changes (status \(status))"])
            }
        }
        // Apple's SCPreferences helper requests the precise required rights,
        // allowing interaction only when needed for this requested write.
        guard let preferences = SCPreferencesCreateWithAuthorization(nil, "ProxyTray" as CFString, nil, authorization) else {
            throw systemError("Open authorized network preferences")
        }
        return preferences
    }

    private func proxyConfiguration(service: NetworkProxyService, preferences: SCPreferences) throws -> (proxy: SCNetworkProtocol, configuration: [String: Any]) {
        guard let networkService = SCNetworkServiceCopy(preferences, service.id as CFString) else {
            if SCError() == kSCStatusNoKey { throw NetworkProxyStoreError.missingService(service.name) }
            throw systemError("Read network service \"\(service.name)\"")
        }
        guard let proxy = SCNetworkServiceCopyProtocol(networkService, kSCNetworkProtocolTypeProxies) else {
            throw systemError("Read proxy settings for \"\(service.name)\"")
        }
        return (proxy, SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:])
    }

    private func systemError(_ operation: String) -> NSError {
        let code = SCError()
        let detail = String(cString: SCErrorString(code))
        return NSError(domain: "ProxyTray.Network", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(detail) (\(code))"])
    }
}
