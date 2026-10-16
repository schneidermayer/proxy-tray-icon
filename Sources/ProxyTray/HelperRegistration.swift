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
    private let waitForRetry: (TimeInterval) -> Void

    init(service: HelperServiceManaging, loadVersion: @escaping () -> String?, saveVersion: @escaping (String) -> Void,
         waitForRetry: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.service = service
        self.loadVersion = loadVersion
        self.saveVersion = saveVersion
        self.waitForRetry = waitForRetry
    }

    func prepare(version: String) throws -> HelperServiceStatus {
        let status = service.status
        if (status == .enabled || status == .requiresApproval), loadVersion() == version {
            return status
        }
        let replacingRegistration = status == .enabled || status == .requiresApproval
        if replacingRegistration {
            try service.unregister()
        }
        let retryDelays: [TimeInterval] = [0.1, 0.25, 0.5, 1, 2]
        var retry = 0
        while true {
            do {
                try service.register()
                break
            } catch {
                // ServiceManagement can report a denied launch after successfully
                // registering the daemon, while approval is pending in Settings.
                if service.status == .requiresApproval { break }
                let failure = error as NSError
                // macOS can finish unregister's completion before launchd permits
                // re-registration (Apple DTS: forums/thread/783539). Retry only
                // this post-unregister EPERM, with a bounded settling period.
                guard replacingRegistration, service.status == .notRegistered,
                      failure.code == 1,
                      failure.domain == "SMAppServiceErrorDomain",
                      retry < retryDelays.count else { throw error }
                waitForRetry(retryDelays[retry])
                retry += 1
            }
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
