import Foundation

enum HelperServiceStatus { case notRegistered, enabled, requiresApproval, notFound }

protocol HelperServiceManaging {
    var status: HelperServiceStatus { get }
    func register() throws
    /// Must return only after the previous service process has exited.
    func unregister() throws
}

/// A build change refreshes the registered executable. Reopening the same
/// installed build leaves both the service and the user's approval alone.
final class HelperRegistration {
    private let service: HelperServiceManaging
    private let loadVersion: () -> String?
    private let saveVersion: (String) -> Void

    init(service: HelperServiceManaging, loadVersion: @escaping () -> String?, saveVersion: @escaping (String) -> Void) {
        self.service = service
        self.loadVersion = loadVersion
        self.saveVersion = saveVersion
    }

    func prepare(version: String) throws -> HelperServiceStatus {
        let status = service.status
        if (status == .enabled || status == .requiresApproval), loadVersion() == version {
            return status
        }
        if status == .enabled || status == .requiresApproval {
            try service.unregister()
        }
        do {
            try service.register()
        } catch {
            // ServiceManagement can report a denied launch after successfully
            // registering the daemon, while approval is pending in Settings.
            guard service.status == .requiresApproval else { throw error }
        }
        let registeredStatus = service.status
        guard registeredStatus == .enabled || registeredStatus == .requiresApproval else {
            throw NSError(domain: "ProxyTray.NetworkHelper", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "macOS did not register the ProxyTray network helper."])
        }
        saveVersion(version)
        return registeredStatus
    }
}
