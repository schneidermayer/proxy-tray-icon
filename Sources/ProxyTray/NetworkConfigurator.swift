import Darwin
import Foundation

/// Restores only the PAC/SOCKS fields changed by this app. The journal is written
/// before each system change so interruption between commit and apply is recoverable.
final class NetworkConfigurator {
    private let store: NetworkProxyStore
    private let stateURL: URL

    init(
        store: NetworkProxyStore = SystemNetworkProxyStore(),
        stateURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".proxy-tray/network-state.json")
    ) {
        self.store = store
        self.stateURL = stateURL
    }

    enum ProxyState { case none, pac, socks }

    private struct Ownership: Codable {
        var service: NetworkProxyService
        var original: NetworkProxySettings
        var expected: NetworkProxySettings
        var pending: NetworkProxySettings?
        var restoring: Bool
        var ownsPAC: Bool
        var ownsSOCKS: Bool
    }

    private struct Journal: Codable {
        var version = 1
        var services: [String: Ownership] = [:]
    }

    var restorationIssue: String? {
        do { _ = try loadJournal(); return nil }
        catch { return error.localizedDescription }
    }

    var hasPendingRestoration: Bool {
        (try? loadJournal().services.isEmpty == false) ?? true
    }

    func enablePACProxy(pacURLString: String) throws {
        try activate(pacURLString: pacURLString)
    }

    func enableRouteAllProxy() throws {
        try activate(pacURLString: nil)
    }

    private func activate(pacURLString: String?) throws {
        var journal = try loadJournal()
        do {
            let services = try store.services()
            guard !services.isEmpty else { throw failure("No usable network services found") }
            guard journal.services.values.allSatisfy({ $0.pending == nil }),
                  Set(journal.services.keys).isSubset(of: Set(services.map(\.id))) else {
                throw failure("There are unfinished proxy changes. Restore the previous settings before reconnecting.")
            }
            // Preflight every service before touching any settings or credentials.
            var snapshots: [(NetworkProxyService, NetworkProxySettings)] = []
            for service in services {
                let current = try store.read(service: service)
                guard !current.authenticatedSOCKS else {
                    throw failure("\(service.name) has authenticated SOCKS settings. ProxyTray cannot safely replace or restore their credentials.")
                }
                if let owned = journal.services[service.id] {
                    guard owned.pending == nil else {
                        throw failure("\(service.name) has an unfinished proxy change. Restore the previous settings before reconnecting.")
                    }
                    guard current == owned.expected else {
                        throw failure("Proxy settings for \(service.name) changed outside ProxyTray. They will not be overwritten.")
                    }
                }
                snapshots.append((service, current))
            }

            for (service, current) in snapshots {
                let desired = try current.configured(pacURLString: pacURLString)
                guard desired != current else { continue }
                var owned = journal.services[service.id] ?? Ownership(
                    service: service, original: current, expected: current,
                    pending: nil, restoring: false, ownsPAC: false, ownsSOCKS: false
                )
                owned.ownsPAC = owned.ownsPAC || !current.matchesPAC(desired)
                owned.ownsSOCKS = owned.ownsSOCKS || !current.matchesSOCKS(desired)
                owned.pending = desired
                journal.services[service.id] = owned
                try saveJournal(journal)
                try store.write(service: service, expected: current, desired: desired)
                owned.expected = desired
                owned.pending = nil
                journal.services[service.id] = owned
                try saveJournal(journal)
            }
        } catch {
            let rollbackErrors = disableProxy()
            let suffix = rollbackErrors.isEmpty ? "" : "\n\nRestoring previous proxy settings failed:\n" + rollbackErrors.joined(separator: "\n")
            throw failure(error.localizedDescription + suffix)
        }
    }

    @discardableResult
    func disableProxy() -> [String] {
        var journal: Journal
        do { journal = try loadJournal() }
        catch { return [error.localizedDescription] }
        guard !journal.services.isEmpty else { return [] }

        var failures: [String] = []
        for id in journal.services.keys.sorted() {
            guard var owned = journal.services[id] else { continue }
            do {
                let current = try store.read(service: owned.service)
                // Treat each proxy family separately: changing a PAC URL outside
                // this app must not prevent restoration of our SOCKS configuration.
                if !current.matchesPAC(owned.expected) && !(owned.pending.map { current.matchesPAC($0) } ?? false) {
                    owned.ownsPAC = false
                }
                if !current.matchesSOCKS(owned.expected) && !(owned.pending.map { current.matchesSOCKS($0) } ?? false) {
                    owned.ownsSOCKS = false
                }
                let desired = try current.restoring(
                    owned.original, pac: owned.ownsPAC, socks: owned.ownsSOCKS
                )
                // Persist released ownership before any restore; a retry must not
                // claim a user's intervening changes as ours.
                let needsWrite = desired != current || (owned.restoring && (owned.ownsPAC || owned.ownsSOCKS))
                owned.expected = current
                owned.pending = desired
                owned.restoring = needsWrite
                journal.services[id] = owned
                try saveJournal(journal)
                if needsWrite {
                    try store.write(service: owned.service, expected: current, desired: desired)
                }
                journal.services.removeValue(forKey: id)
                try saveJournal(journal)
            } catch NetworkProxyStoreError.missingService(_) {
                // A deleted service has no remaining settings to restore. A
                // disabled service or one in another location still exists and
                // must retain its recovery record until restoration succeeds.
                journal.services.removeValue(forKey: id)
                do { try saveJournal(journal) }
                catch { failures.append("Could not clear the deleted service \"\(owned.service.name)\" from the restoration journal: \(error.localizedDescription)") }
            } catch {
                failures.append("Could not restore proxy settings for \"\(owned.service.name)\": \(error.localizedDescription)")
            }
        }
        return failures
    }

    func detectProxyState() -> ProxyState {
        guard let journal = try? loadJournal(), journal.services.values.allSatisfy({ $0.pending == nil }) else { return .none }
        var hasPAC = false
        for owned in journal.services.values {
            guard owned.pending == nil, let current = try? store.read(service: owned.service) else { continue }
            if owned.ownsSOCKS && current.matchesSOCKS(owned.expected) && current.socksEnabled {
                return .socks
            }
            if owned.ownsPAC && current.matchesPAC(owned.expected) && current.pacEnabled {
                hasPAC = true
            }
        }
        return hasPAC ? .pac : .none
    }

    private func loadJournal() throws -> Journal {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return Journal() }
        do {
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: stateURL))
            guard journal.version == 1 else { throw failure("Unsupported journal version") }
            for (id, owned) in journal.services {
                guard id == owned.service.id else { throw failure("Invalid service identifier") }
                try owned.original.validate()
                try owned.expected.validate()
                try owned.pending?.validate()
            }
            return journal
        } catch {
            throw failure("Could not read the proxy restoration journal at \(stateURL.path): \(error.localizedDescription). Keep this file so the previous settings can be recovered.")
        }
    }

    private func saveJournal(_ journal: Journal) throws {
        // Keep an empty journal too: an atomic replacement never creates a gap
        // during which an interrupted cleanup could lose recovery information.
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(journal)
        let temporaryURL = stateURL.deletingLastPathComponent()
            .appendingPathComponent(".network-state-\(UUID().uuidString)")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        // POSIX rename atomically replaces an existing journal and preserves the
        // temporary file's 0600 mode, even when the parent directory is public.
        guard rename(temporaryURL.path, stateURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "ProxyTray.Network", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
