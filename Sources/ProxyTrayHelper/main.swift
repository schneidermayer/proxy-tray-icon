import Foundation
import ProxyNetwork
import Darwin

@available(macOS 13.0, *)
private final class NetworkHelper: NSObject, NSXPCListenerDelegate, ProxyNetworkHelperProtocol {
    private let clientRequirement: String
    private let store = SystemNetworkProxyStore()
    // Serialize writes from all connections, not just calls on one connection.
    private let writes = DispatchQueue(label: "net.hsch.proxytray.network-helper.writes")

    init(clientRequirement: String) {
        self.clientRequirement = clientRequirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: ProxyNetworkHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func write(_ request: Data, withReply reply: @escaping (NSError?) -> Void) {
        writes.async {
            do {
                try NetworkProxyWriteRequest.perform(data: request, store: self.store)
                reply(nil)
            } catch {
                reply(ProxyNetworkHelperError.encode(error))
            }
        }
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        reply("ProxyTrayHelper/1")
    }
}

guard geteuid() == 0 else {
    fputs("ProxyTrayHelper must be launched by macOS as a privileged service.\n", stderr)
    exit(1)
}
if #available(macOS 13.0, *) {
    do {
        let requirement = try HelperCodeIdentity.requirement(for: "net.hsch.proxytray")
        let delegate = NetworkHelper(clientRequirement: requirement)
        let listener = NSXPCListener(machServiceName: ProxyNetworkHelperConstants.serviceName)
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = delegate
        listener.resume()
        withExtendedLifetime((listener, delegate)) { RunLoop.current.run() }
    } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else {
    exit(1)
}
