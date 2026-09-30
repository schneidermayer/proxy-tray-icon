import XCTest
@testable import ProxyTray

final class NetworkConfiguratorTests: XCTestCase {
    private var directory: URL!
    private var stateURL: URL { directory.appendingPathComponent("network-state.json") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testInactiveDetectionAndCleanupDoNotReadOrChangeForeignProxies() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        XCTAssertEqual(network.detectProxyState(), .none)
        XCTAssertEqual(network.disableProxy(), [])
        XCTAssertFalse(network.hasPendingRestoration)
        XCTAssertNil(network.restorationIssue)
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(store.writes, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testRestoresExistingPACAndSOCKSAfterMultipleModeChanges() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        try network.enablePACProxy(pacURLString: "data:our-pac")
        XCTAssertEqual(network.detectProxyState(), .pac)
        try network.enableRouteAllProxy()
        XCTAssertEqual(network.detectProxyState(), .socks)
        try network.enablePACProxy(pacURLString: "data:updated-pac")
        XCTAssertEqual(network.disableProxy(), [])

        assertConfiguration(store.configurations["wifi"], equals: foreignSettings)
        XCTAssertFalse(network.hasPendingRestoration)
        XCTAssertEqual(network.detectProxyState(), .none)
    }

    func testRestoresOriginallyAbsentKeysAndPreservesUnrelatedSettings() throws {
        let original: [String: Any] = ["HTTPEnable": 1, "HTTPProxy": "corporate", "ExceptionsList": ["localhost"]]
        let store = FakeNetworkProxyStore(configurations: ["wifi": original])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        try network.enableRouteAllProxy()
        try network.enablePACProxy(pacURLString: "data:our-pac")
        XCTAssertEqual(network.disableProxy(), [])

        assertConfiguration(store.configurations["wifi"], equals: original)
    }

    func testReplacesAndRestoresInlinePACScript() throws {
        var original = foreignSettings
        original["ProxyAutoConfigJavaScript"] = "function FindProxyForURL() { return 'DIRECT'; }"
        let store = FakeNetworkProxyStore(configurations: ["wifi": original])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        try network.enablePACProxy(pacURLString: "data:our-pac")
        XCTAssertNil(store.configurations["wifi"]?["ProxyAutoConfigJavaScript"])
        XCTAssertEqual(network.disableProxy(), [])
        assertConfiguration(store.configurations["wifi"], equals: original)
    }

    func testOwnershipSurvivesCreatingAnotherConfigurator() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        try NetworkConfigurator(store: store, stateURL: stateURL).enableRouteAllProxy()
        let relaunched = NetworkConfigurator(store: store, stateURL: stateURL)

        XCTAssertTrue(relaunched.hasPendingRestoration)
        XCTAssertEqual(relaunched.detectProxyState(), .socks)
        XCTAssertEqual(relaunched.disableProxy(), [])
        assertConfiguration(store.configurations["wifi"], equals: foreignSettings)
    }

    func testRestoresOurSOCKSChangesWithoutOverwritingExternallyChangedPAC() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        try network.enableRouteAllProxy()
        store.configurations["wifi"]?["ProxyAutoConfigEnable"] = 1
        store.configurations["wifi"]?["ProxyAutoConfigURLString"] = "https://new-owner/pac"
        store.configurations["wifi"]?["HTTPProxy"] = "new-http-proxy"

        XCTAssertEqual(network.disableProxy(), [])

        var expected = foreignSettings
        expected["ProxyAutoConfigURLString"] = "https://new-owner/pac"
        expected["HTTPProxy"] = "new-http-proxy"
        assertConfiguration(store.configurations["wifi"], equals: expected)
        XCTAssertFalse(network.hasPendingRestoration)
    }

    func testExternalSOCKSChangeIsPreservedDuringCleanup() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        try network.enableRouteAllProxy()
        store.configurations["wifi"]?["SOCKSProxy"] = "new-owner"
        store.configurations["wifi"]?["SOCKSPort"] = 9000
        store.configurations["wifi"]?["SOCKSUser"] = "new-authenticated-user"

        XCTAssertEqual(network.disableProxy(), [])

        var expected = foreignSettings
        expected["SOCKSProxy"] = "new-owner"
        expected["SOCKSPort"] = 9000
        expected["SOCKSUser"] = "new-authenticated-user"
        assertConfiguration(store.configurations["wifi"], equals: expected)
    }

    func testPartialActivationFailureRollsBackAllCompletedServices() throws {
        let store = FakeNetworkProxyStore(configurations: ["a": foreignSettings, "b": foreignSettings])
        store.beforeWrite = { service, _, desired in
            if service.id == "b", desired.socksEnabled,
               try desired.dictionary()["SOCKSProxy"] as? String == "127.0.0.1" {
                throw Self.error("Authorization denied")
            }
        }
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        XCTAssertThrowsError(try network.enableRouteAllProxy()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Authorization denied"))
        }

        assertConfiguration(store.configurations["a"], equals: foreignSettings)
        assertConfiguration(store.configurations["b"], equals: foreignSettings)
        XCTAssertFalse(network.hasPendingRestoration)
    }

    func testCleanupFailureContinuesOtherServicesAndRetainsRetryableJournal() throws {
        let store = FakeNetworkProxyStore(configurations: ["a": foreignSettings, "b": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        try network.enableRouteAllProxy()
        store.beforeWrite = { service, _, _ in
            if service.id == "a" { throw Self.error("Network preferences locked") }
        }

        let errors = network.disableProxy()

        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("a"))
        XCTAssertTrue(errors[0].contains("Network preferences locked"))
        assertConfiguration(store.configurations["b"], equals: foreignSettings)
        XCTAssertTrue(network.hasPendingRestoration)
        XCTAssertEqual(network.detectProxyState(), .none)
        store.beforeWrite = nil
        let relaunched = NetworkConfigurator(store: store, stateURL: stateURL)
        XCTAssertEqual(relaunched.disableProxy(), [])
        assertConfiguration(store.configurations["a"], equals: foreignSettings)
        XCTAssertFalse(relaunched.hasPendingRestoration)
    }

    func testApplyFailureAfterCommitCanBeRetriedMoreThanOnce() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        try network.enableRouteAllProxy()
        store.afterWrite = { _, _, _ in throw Self.error("Apply failed after commit") }

        XCTAssertEqual(network.disableProxy().count, 1)
        XCTAssertEqual(network.disableProxy().count, 1)
        XCTAssertTrue(network.hasPendingRestoration)

        store.afterWrite = nil
        let writesBeforeRetry = store.writes.count
        XCTAssertEqual(network.disableProxy(), [])
        XCTAssertEqual(store.writes.count, writesBeforeRetry + 1)
        XCTAssertFalse(network.hasPendingRestoration)
        assertConfiguration(store.configurations["wifi"], equals: foreignSettings)
    }

    func testJournalIsPersistedBeforeEverySystemMutation() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        store.beforeWrite = { [self] _, _, _ in
            let data = try Data(contentsOf: stateURL)
            let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let services = try XCTUnwrap(journal["services"] as? [String: Any])
            let service = try XCTUnwrap(services["wifi"] as? [String: Any])
            XCTAssertNotNil(service["original"])
            XCTAssertNotNil(service["pending"])
        }
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        try network.enableRouteAllProxy()
        XCTAssertEqual(network.disableProxy(), [])
    }

    func testJournalIsPrivateInsideExistingPublicDirectory() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        store.beforeWrite = { [self] _, _, _ in
            let mode = try FileManager.default.attributesOfItem(atPath: stateURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }

        try network.enableRouteAllProxy()
        XCTAssertEqual(network.disableProxy(), [])

        let parentMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(parentMode?.intValue, 0o755)
        let children = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(children, ["network-state.json"])
    }

    func testDeletedOwnedServiceReleasesJournalAndAllowsReconnect() throws {
        let store = FakeNetworkProxyStore(configurations: ["deleted": foreignSettings, "wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        try network.enableRouteAllProxy()
        store.configurations.removeValue(forKey: "deleted")

        XCTAssertEqual(network.disableProxy(), [])
        XCTAssertFalse(network.hasPendingRestoration)
        assertConfiguration(store.configurations["wifi"], equals: foreignSettings)
        try network.enablePACProxy(pacURLString: "data:our-pac")
        XCTAssertEqual(network.detectProxyState(), .pac)
        XCTAssertEqual(network.disableProxy(), [])
    }

    func testTransientServiceReadFailureRetainsRecoveryForRetry() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)
        try network.enableRouteAllProxy()
        store.readError = Self.error("Access denied")

        XCTAssertEqual(network.disableProxy().count, 1)
        XCTAssertTrue(network.hasPendingRestoration)

        store.readError = nil
        XCTAssertEqual(network.disableProxy(), [])
        XCTAssertFalse(network.hasPendingRestoration)
        assertConfiguration(store.configurations["wifi"], equals: foreignSettings)
    }

    func testAuthenticatedSOCKSPreflightRefusesBeforeAnyMutation() throws {
        var authenticated = foreignSettings
        authenticated["SOCKSUser"] = "username"
        authenticated["SOCKSEnable"] = 0
        let store = FakeNetworkProxyStore(configurations: ["a": foreignSettings, "b": authenticated])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        XCTAssertThrowsError(try network.enableRouteAllProxy()) { error in
            XCTAssertTrue(error.localizedDescription.contains("authenticated SOCKS"))
        }

        XCTAssertEqual(store.writes, [])
        assertConfiguration(store.configurations["b"], equals: authenticated)
        XCTAssertFalse(network.hasPendingRestoration)
    }

    func testCorruptJournalIsReportedAndNeverOverwrittenOrUsedForChanges() throws {
        let data = Data("invalid journal".utf8)
        try data.write(to: stateURL)
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        XCTAssertNotNil(network.restorationIssue)
        XCTAssertTrue(network.hasPendingRestoration)
        XCTAssertEqual(network.detectProxyState(), .none)
        XCTAssertFalse(network.disableProxy().isEmpty)
        XCTAssertThrowsError(try network.enableRouteAllProxy())
        XCTAssertEqual(store.writes, [])
        XCTAssertEqual(try Data(contentsOf: stateURL), data)
    }

    func testJournalWriteFailurePreventsSystemMutation() throws {
        let parentFile = directory.appendingPathComponent("not-a-directory")
        try Data().write(to: parentFile)
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        let network = NetworkConfigurator(store: store, stateURL: parentFile.appendingPathComponent("state.json"))

        XCTAssertThrowsError(try network.enableRouteAllProxy())
        XCTAssertEqual(store.writes, [])
        assertConfiguration(store.configurations["wifi"], equals: foreignSettings)
    }

    func testEnumerationFailureReportsUnderlyingErrorWithoutMutatingSettings() throws {
        let store = FakeNetworkProxyStore(configurations: ["wifi": foreignSettings])
        store.enumerationError = Self.error("Network configuration unavailable")
        let network = NetworkConfigurator(store: store, stateURL: stateURL)

        XCTAssertThrowsError(try network.enableRouteAllProxy()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Network configuration unavailable"))
        }
        XCTAssertEqual(store.writes, [])
    }

    private var foreignSettings: [String: Any] {
        ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://corporate/pac",
         "SOCKSEnable": 1, "SOCKSProxy": "existing-socks", "SOCKSPort": 8080,
         "HTTPEnable": 1, "HTTPProxy": "existing-http", "HTTPPort": 3128]
    }

    private func assertConfiguration(_ actual: [String: Any]?, equals expected: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(NSDictionary(dictionary: actual ?? [:]).isEqual(to: expected), "Unexpected proxy configuration: \(actual ?? [:])", file: file, line: line)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "NetworkConfiguratorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class FakeNetworkProxyStore: NetworkProxyStore {
    var configurations: [String: [String: Any]]
    var writes: [String] = []
    var readCount = 0
    var enumerationError: Error?
    var readError: Error?
    var beforeWrite: ((NetworkProxyService, NetworkProxySettings, NetworkProxySettings) throws -> Void)?
    var afterWrite: ((NetworkProxyService, NetworkProxySettings, NetworkProxySettings) throws -> Void)?

    init(configurations: [String: [String: Any]]) { self.configurations = configurations }

    func services() throws -> [NetworkProxyService] {
        if let enumerationError { throw enumerationError }
        return configurations.keys.sorted().map { NetworkProxyService(id: $0, name: $0) }
    }

    func read(service: NetworkProxyService) throws -> NetworkProxySettings {
        readCount += 1
        if let readError { throw readError }
        guard let configuration = configurations[service.id] else { throw NetworkProxyStoreError.missingService(service.name) }
        return try NetworkProxySettings(configuration: configuration)
    }

    func write(service: NetworkProxyService, expected: NetworkProxySettings, desired: NetworkProxySettings) throws {
        try beforeWrite?(service, expected, desired)
        let current = try read(service: service)
        guard current == expected else {
            throw NSError(domain: "NetworkConfiguratorTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Concurrent external proxy change"])
        }
        var configuration = configurations[service.id] ?? [:]
        let replacement = try desired.dictionary()
        for key in NetworkProxySettings.pacKeys + NetworkProxySettings.socksKeys {
            configuration[key] = replacement[key]
        }
        configurations[service.id] = configuration
        writes.append(service.id)
        try afterWrite?(service, expected, desired)
    }
}
