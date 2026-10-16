import Foundation

public enum ProxyNetworkHelperConstants {
    public static let serviceName = "net.hsch.proxytray.network-helper"
    public static let plistName = serviceName + ".plist"
}

/// The privileged process accepts only bounded proxy-setting updates. No paths,
/// commands, credentials, or general SystemConfiguration operations cross XPC.
@objc public protocol ProxyNetworkHelperProtocol {
    func write(_ request: Data, withReply reply: @escaping (NSError?) -> Void)
    func ping(withReply reply: @escaping (String) -> Void)
}

public struct NetworkProxyWriteRequest: Codable {
    public static let maximumBytes = 1_048_576

    public let service: NetworkProxyService
    public let expected: NetworkProxySettings
    public let desired: NetworkProxySettings

    public init(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) {
        self.service = service
        self.expected = expected
        self.desired = desired
    }

    public static func perform(data: Data, store: NetworkProxyStore) throws {
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw invalidRequest("Invalid proxy request size")
        }
        // Codable normally ignores unknown keys. At the privilege boundary,
        // require this exact schema instead of accepting ambiguous extensions.
        let object = try JSONSerialization.jsonObject(with: data)
        let envelope = try fields(object, keys: ["service", "expected", "desired"])
        _ = try fields(envelope["service"], keys: ["id", "name"])
        _ = try fields(envelope["expected"], keys: ["values", "authenticatedSOCKS"])
        _ = try fields(envelope["desired"], keys: ["values", "authenticatedSOCKS"])

        let request = try JSONDecoder().decode(Self.self, from: data)
        let allowedID = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard !request.service.id.isEmpty,
              request.service.id.utf8.count <= 255,
              request.service.id.unicodeScalars.allSatisfy(allowedID.contains),
              request.service.name.utf8.count <= 1024 else {
            throw invalidRequest("Invalid network service identifier")
        }
        try validate(request.expected)
        try validate(request.desired)
        try store.write(service: request.service, expected: request.expected, desired: request.desired)
    }

    private static func fields(_ object: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let dictionary = object as? [String: Any], Set(dictionary.keys) == keys else {
            throw invalidRequest("Invalid proxy request fields")
        }
        return dictionary
    }

    private static func validate(_ settings: NetworkProxySettings) throws {
        // dictionary() rejects any property outside the six managed PAC/SOCKS
        // fields, including credentials and unrelated HTTP proxy settings.
        for (key, value) in try settings.dictionary() {
            switch key {
            case "ProxyAutoConfigEnable", "SOCKSEnable":
                guard let number = value as? NSNumber, number == 0 || number == 1 else {
                    throw invalidRequest("Invalid proxy enable value")
                }
            case "SOCKSPort":
                guard let number = value as? NSNumber,
                      number.doubleValue.isFinite,
                      number.doubleValue.rounded(.towardZero) == number.doubleValue,
                      (0.0...65535.0).contains(number.doubleValue) else {
                    throw invalidRequest("Invalid SOCKS port")
                }
            default:
                guard value is String else { throw invalidRequest("Invalid proxy string value") }
            }
        }
    }

    private static func invalidRequest(_ description: String) -> NSError {
        NSError(domain: "ProxyTray.NetworkHelper.Request", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }
}

public enum ProxyNetworkHelperError {
    private static let domain = "ProxyTray.NetworkHelper.Store"
    private static let serviceNameKey = "ProxyTray.NetworkServiceName"

    public static func encode(_ error: Error) -> NSError {
        if case NetworkProxyStoreError.missingService(let name) = error {
            return NSError(domain: domain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription,
                serviceNameKey: name
            ])
        }
        let underlying = error as NSError
        return NSError(domain: underlying.domain, code: underlying.code,
                       userInfo: [NSLocalizedDescriptionKey: underlying.localizedDescription])
    }

    public static func decode(_ error: NSError) -> Error {
        if error.domain == domain, error.code == 1, let name = error.userInfo[serviceNameKey] as? String {
            return NetworkProxyStoreError.missingService(name)
        }
        return error
    }
}
